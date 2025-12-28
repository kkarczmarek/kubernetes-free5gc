package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"crypto/tls"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// JSON Patch operation
type patchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

var (
	scheme       = runtime.NewScheme()
	codecs       = serializer.NewCodecFactory(scheme)
	deserializer = codecs.UniversalDeserializer()

	// Namespace labels / feature toggles
	admissionLabelKey      = "admission.kkarczmarek.dev/enabled"
	allowNetAdminNsLabel   = "allow-netadmin"
	allowHostPathNsLabel   = "allow-hostpath"
	validateNetworksAnno   = "5g.kkarczmarek.dev/validate-dataplane-cidr"
	requiredPortsAnnotation = "5g.kkarczmarek.dev/required-ports"
	serviceIPAnnotation     = "5g.kkarczmarek.dev/service-ip"

	// Common labels
	projectLabelKey   = "project"
	projectLabelValue = "free5gc"

	partOfLabelKey   = "app.kubernetes.io/part-of"
	partOfLabelValue = "free5gc"

	nfLabelKey = "nf"

	// 5G-specific anotacje (slicing, adresacja)
	sliceIdAnnotation    = "5g.kkarczmarek.dev/slice-id"
	sstAnnotation        = "5g.kkarczmarek.dev/sst"
	sdAnnotation         = "5g.kkarczmarek.dev/sd"
	dnnAnnotation        = "5g.kkarczmarek.dev/dnn"
	uePoolCidrAnnotation = "5g.kkarczmarek.dev/ue-pool-cidr"
	n6CidrAnnotation     = "5g.kkarczmarek.dev/n6-cidr"
	upfNetworksAnnotation    = "5g.kkarczmarek.dev/networks"

	// Tcpdump sidecar
	tcpdumpEnabledAnnotation = "5g.kkarczmarek.dev/tcpdump-enabled"

	// Konfiguracja z env
	denyLatestTag    = getEnvBool("DENY_LATEST_TAG", true)
	dataPlaneCIDR    = getEnv("DATA_CIDR", "10.100.50.0/24") // do walidacji IP z CNI / Service
	tcpdumpImage     = getEnv("TCPDUMP_IMAGE", "ghcr.io/kkarczmarek/tcpdump-sidecar:latest")
	defaultReqCPU    = getEnv("DEFAULT_REQUEST_CPU", "50m")
	defaultReqMemory = getEnv("DEFAULT_REQUEST_MEMORY", "128Mi")
	defaultLimCPU    = getEnv("DEFAULT_LIMIT_CPU", "500m")
	defaultLimMemory = getEnv("DEFAULT_LIMIT_MEMORY", "512Mi")

	ipCidrRegex = regexp.MustCompile(`\b\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}\b`)
)

func main() {
	flagAddr := flag.String("addr", ":8443", "address to listen on")
	flag.Parse()

	// klient do Kubernetes (potrzebny np. w walidacjach)
	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("getting in-cluster config: %v", err)
	}

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("building clientset: %v", err)
	}

	// --- router HTTP ---
	mux := http.NewServeMux()

	// endpoint mutujący
	mux.HandleFunc("/mutate", func(w http.ResponseWriter, r *http.Request) {
		handleMutate(w, r, clientset)
	})

	// endpoint walidujący
	mux.HandleFunc("/validate", func(w http.ResponseWriter, r *http.Request) {
		handleValidate(w, r, clientset)
	})

	// prosty endpoint health-check dla kubeleta
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// serwer HTTPS z naszym muxem
	srv := &http.Server{
		Addr:    *flagAddr,
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("starting webhook server on %s", *flagAddr)
	if err := srv.ListenAndServeTLS("/tls/tls.crt", "/tls/tls.key"); err != nil {
		log.Fatalf("ListenAndServeTLS failed: %v", err)
	}
}


func handleMutate(w http.ResponseWriter, r *http.Request, clientset kubernetes.Interface) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, fmt.Errorf("reading body: %w", err).Error(), http.StatusBadRequest)
		return
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, fmt.Errorf("unmarshal review: %w", err).Error(), http.StatusBadRequest)
		return
	}

	if review.Request == nil {
		http.Error(w, "no request in AdmissionReview", http.StatusBadRequest)
		return
	}
	req := review.Request

	var patch []byte
	switch req.Kind.Kind {
	case "Pod":
		patch, err = mutatePod(req.Object.Raw, req.Namespace, clientset)
	case "Deployment", "StatefulSet", "DaemonSet":
		patch, err = mutateWorkload(req.Object.Raw, req.Namespace, req.Kind.Kind, clientset)
	case "Service":
		patch, err = mutateService(req.Object.Raw, req.Namespace, clientset)
	default:
		// inne typy przepuszczamy bez zmian
	}

	resp := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: admissionv1.SchemeGroupVersion.String(),
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			UID: req.UID,
		},
	}

	if err != nil {
		resp.Response.Allowed = false
		resp.Response.Result = &metav1.Status{
			Message: err.Error(),
		}
	} else {
		resp.Response.Allowed = true
		if len(patch) > 0 {
			pt := admissionv1.PatchTypeJSONPatch
			resp.Response.PatchType = &pt
			resp.Response.Patch = patch
		}
	}

	writeResponse(w, resp)
}

func handleValidate(w http.ResponseWriter, r *http.Request, clientset kubernetes.Interface) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, fmt.Errorf("reading body: %w", err).Error(), http.StatusBadRequest)
		return
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		http.Error(w, fmt.Errorf("unmarshal review: %w", err).Error(), http.StatusBadRequest)
		return
	}

	if review.Request == nil {
		http.Error(w, "no request in AdmissionReview", http.StatusBadRequest)
		return
	}
	req := review.Request

	var errs field.ErrorList
	switch req.Kind.Kind {
	case "Pod":
		errs = validatePod(req.Object.Raw, req.Namespace, clientset)
	case "Deployment", "StatefulSet", "DaemonSet":
		errs = validateWorkload(req.Object.Raw, req.Namespace, req.Kind.Kind, clientset)
	case "Service":
		errs = validateService(req.Object.Raw, req.Namespace, clientset)
	default:
	}

	resp := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: admissionv1.SchemeGroupVersion.String(),
			Kind:       "AdmissionReview",
		},
		Response: &admissionv1.AdmissionResponse{
			UID: req.UID,
		},
	}

	if len(errs) == 0 {
		resp.Response.Allowed = true
	} else {
		resp.Response.Allowed = false
		msgs := make([]string, 0, len(errs))
		for _, e := range errs {
			msgs = append(msgs, e.Error())
		}
		resp.Response.Result = &metav1.Status{
			Message: strings.Join(msgs, "; "),
		}
	}

	writeResponse(w, resp)
}

func writeResponse(w http.ResponseWriter, review admissionv1.AdmissionReview) {
	w.Header().Set("Content-Type", "application/json")
	respBytes, err := json.Marshal(review)
	if err != nil {
		log.Printf("marshal response: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := w.Write(respBytes); err != nil {
		log.Printf("write response: %v", err)
	}
}

// --------- MUTATING: Pod & Workload ---------

func mutatePod(raw []byte, namespace string, clientset kubernetes.Interface) ([]byte, error) {
	pod := &corev1.Pod{}
	if _, _, err := deserializer.Decode(raw, nil, pod); err != nil {
		return nil, fmt.Errorf("decode pod: %w", err)
	}

	ctx := context.Background()
	shouldHandle, nsObj, err := shouldHandleNamespace(ctx, clientset, namespace)
	if err != nil {
		return nil, err
	}
	if !shouldHandle {
		return nil, nil
	}

	var ops []patchOp

	// wspólne labele project/part-of
	ops = append(ops, ensureCommonLabels(&pod.ObjectMeta, "/metadata", nsObj)...)

	// kopiowanie anotacji 5g.* -> labele (dla free5gc)
	if isFree5gcWorkload(pod.ObjectMeta, nsObj.Name) {
		ops = append(ops, copy5gAnnotationsToLabels(pod.Annotations, pod.Labels, "/metadata")...)
	}

	// zasoby + securityContext dla kontenerów
	ops = append(ops, ensureContainers(pod.Spec.Containers, "/spec/containers")...)
	ops = append(ops, ensureContainers(pod.Spec.InitContainers, "/spec/initContainers")...)

	// UPF: domyślne porty + ewentualny sidecar tcpdump
	if isUpfPod(pod) {
		ops = append(ops, ensureUpfDefaultPorts(&pod.Spec, "/spec/containers")...)
		if isTcpdumpEnabled(pod.Annotations) {
			ops = append(ops, injectTcpdumpSidecar(&pod.Spec, "/spec/containers", "/spec/volumes", pod.Annotations)...)
		}
	}

	if len(ops) == 0 {
		return nil, nil
	}
	return json.Marshal(ops)
}

func mutateWorkload(raw []byte, namespace, kind string, clientset kubernetes.Interface) ([]byte, error) {
	var (
		meta metav1.ObjectMeta
		tpl  *corev1.PodTemplateSpec
	)

	switch kind {
	case "Deployment":
		obj := &appsv1.Deployment{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return nil, fmt.Errorf("decode deployment: %w", err)
		}
		meta = obj.ObjectMeta
		tpl = &obj.Spec.Template
	case "StatefulSet":
		obj := &appsv1.StatefulSet{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return nil, fmt.Errorf("decode statefulset: %w", err)
		}
		meta = obj.ObjectMeta
		tpl = &obj.Spec.Template
	case "DaemonSet":
		obj := &appsv1.DaemonSet{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return nil, fmt.Errorf("decode daemonset: %w", err)
		}
		meta = obj.ObjectMeta
		tpl = &obj.Spec.Template
	default:
		return nil, nil
	}

	ctx := context.Background()
	shouldHandle, nsObj, err := shouldHandleNamespace(ctx, clientset, namespace)
	if err != nil {
		return nil, err
	}
	if !shouldHandle {
		return nil, nil
	}

	var ops []patchOp

	// labele project/part-of na Workloadzie
	ops = append(ops, ensureCommonLabels(&meta, "/metadata", nsObj)...)
	// ...i na template
	ops = append(ops, ensureCommonLabels(&tpl.ObjectMeta, "/spec/template/metadata", nsObj)...)

	// kopiowanie 5g.* z anotacji template -> labele template
	if isFree5gcWorkload(tpl.ObjectMeta, nsObj.Name) {
		ops = append(ops, copy5gAnnotationsToLabels(tpl.Annotations, tpl.Labels, "/spec/template/metadata")...)
	}

	// zasoby + securityContext
	ops = append(ops, ensureContainers(tpl.Spec.Containers, "/spec/template/spec/containers")...)
	ops = append(ops, ensureContainers(tpl.Spec.InitContainers, "/spec/template/spec/initContainers")...)

	// UPF: domyślne porty + sidecar tcpdump
	if isUpfPodTemplate(tpl) {
		ops = append(ops, ensureUpfDefaultPorts(&tpl.Spec, "/spec/template/spec/containers")...)
		if isTcpdumpEnabled(tpl.Annotations) {
			ops = append(ops, injectTcpdumpSidecar(&tpl.Spec, "/spec/template/spec/containers", "/spec/template/spec/volumes", tpl.Annotations)...)
		}
	}

	if len(ops) == 0 {
		return nil, nil
	}
	return json.Marshal(ops)
}

// Mutating dla Service (IP + labele)
func mutateService(raw []byte, namespace string, clientset kubernetes.Interface) ([]byte, error) {
	svc := &corev1.Service{}
	if _, _, err := deserializer.Decode(raw, nil, svc); err != nil {
		return nil, fmt.Errorf("decode service: %w", err)
	}

	ctx := context.Background()
	shouldHandle, nsObj, err := shouldHandleNamespace(ctx, clientset, namespace)
	if err != nil {
		return nil, err
	}
	if !shouldHandle {
		return nil, nil
	}

	var ops []patchOp

	// upewnij się, że mamy mapę labeli
	if svc.Labels == nil {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  "/metadata/labels",
			Value: map[string]string{},
		})
		svc.Labels = map[string]string{}
	}

	// w free5gc dodaj domyślne labele projektu
	if nsObj.Name == "free5gc" {
		if svc.Labels[projectLabelKey] == "" {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  "/metadata/labels/" + escapeJSONPointer(projectLabelKey),
				Value: projectLabelValue,
			})
		}
		if svc.Labels[partOfLabelKey] == "" {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  "/metadata/labels/" + escapeJSONPointer(partOfLabelKey),
				Value: partOfLabelValue,
			})
		}
	}

	// Jeśli anotacja service-ip jest ustawiona, ustaw clusterIP (np. do wymuszenia konkretnego IP)
	if ipAnnotation, ok := svc.Annotations[serviceIPAnnotation]; ok {
		ipStr := strings.TrimSpace(ipAnnotation)
		if ipStr != "" && svc.Spec.ClusterIP == "" {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  "/spec/clusterIP",
				Value: ipStr,
			})
		}
	}

	if len(ops) == 0 {
		return nil, nil
	}
	return json.Marshal(ops)
}

// --------- WSPÓLNE POMOCNICZE (mutating) ---------

func ensureCommonLabels(meta *metav1.ObjectMeta, basePath string, ns *corev1.Namespace) []patchOp {
	var ops []patchOp

	if meta.Labels == nil {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  basePath + "/labels",
			Value: map[string]string{},
		})
		meta.Labels = map[string]string{}
	}

	if ns.Name == "free5gc" && meta.Labels[projectLabelKey] == "" {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  basePath + "/labels/" + escapeJSONPointer(projectLabelKey),
			Value: projectLabelValue,
		})
	}
	if ns.Name == "free5gc" && meta.Labels[partOfLabelKey] == "" {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  basePath + "/labels/" + escapeJSONPointer(partOfLabelKey),
			Value: partOfLabelValue,
		})
	}

	return ops
}

func copy5gAnnotationsToLabels(ann, labels map[string]string, baseMetaPath string) []patchOp {
	if ann == nil {
		return nil
	}

	var ops []patchOp

	if labels == nil {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  baseMetaPath + "/labels",
			Value: map[string]string{},
		})
		labels = map[string]string{}
	}

	keys := []string{
		sliceIdAnnotation,
		sstAnnotation,
		sdAnnotation,
		dnnAnnotation,
		uePoolCidrAnnotation,
		n6CidrAnnotation,
	}

	for _, k := range keys {
		v, ok := ann[k]
		if !ok || v == "" {
			continue
		}
		if labels[k] == v {
			continue
		}
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  fmt.Sprintf("%s/labels/%s", baseMetaPath, escapeJSONPointer(k)),
			Value: v,
		})
	}

	return ops
}

func ensureContainers(containers []corev1.Container, basePath string) []patchOp {
	var ops []patchOp

	for i, c := range containers {
		containerPath := fmt.Sprintf("%s/%d", basePath, i)

		// Resources: CPU/memory requests/limits
		res := c.Resources
		if len(res.Requests) == 0 && len(res.Limits) == 0 {
			ops = append(ops, patchOp{
				Op:   "add",
				Path: containerPath + "/resources",
				Value: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(defaultReqCPU),
						corev1.ResourceMemory: resource.MustParse(defaultReqMemory),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(defaultLimCPU),
						corev1.ResourceMemory: resource.MustParse(defaultLimMemory),
					},
				},
			})
		} else {
			// Uzupełnianie brakujących kluczy
			if res.Requests == nil {
				ops = append(ops, patchOp{
					Op:   "add",
					Path: containerPath + "/resources/requests",
					Value: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(defaultReqCPU),
						corev1.ResourceMemory: resource.MustParse(defaultReqMemory),
					},
				})
			} else {
				if _, ok := res.Requests[corev1.ResourceCPU]; !ok {
					ops = append(ops, patchOp{
						Op:    "add",
						Path:  containerPath + "/resources/requests/cpu",
						Value: resource.MustParse(defaultReqCPU),
					})
				}
				if _, ok := res.Requests[corev1.ResourceMemory]; !ok {
					ops = append(ops, patchOp{
						Op:    "add",
						Path:  containerPath + "/resources/requests/memory",
						Value: resource.MustParse(defaultReqMemory),
					})
				}
			}

			if res.Limits == nil {
				ops = append(ops, patchOp{
					Op:   "add",
					Path: containerPath + "/resources/limits",
					Value: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(defaultLimCPU),
						corev1.ResourceMemory: resource.MustParse(defaultLimMemory),
					},
				})
			} else {
				if _, ok := res.Limits[corev1.ResourceCPU]; !ok {
					ops = append(ops, patchOp{
						Op:    "add",
						Path:  containerPath + "/resources/limits/cpu",
						Value: resource.MustParse(defaultLimCPU),
					})
				}
				if _, ok := res.Limits[corev1.ResourceMemory]; !ok {
					ops = append(ops, patchOp{
						Op:    "add",
						Path:  containerPath + "/resources/limits/memory",
						Value: resource.MustParse(defaultLimMemory),
					})
				}
			}
		}

		// securityContext: drop ALL, seccomp
		ops = append(ops, ensureSecurityContext(&c, containerPath)...)
	}

	return ops
}

func ensureSecurityContext(c *corev1.Container, basePath string) []patchOp {
	var ops []patchOp

	if c.SecurityContext == nil {
		ops = append(ops, patchOp{
			Op:   "add",
			Path: basePath + "/securityContext",
			Value: &corev1.SecurityContext{
				AllowPrivilegeEscalation: boolPtr(false),
				Capabilities: &corev1.Capabilities{
					Drop: []corev1.Capability{"ALL"},
				},
				SeccompProfile: &corev1.SeccompProfile{
					Type: corev1.SeccompProfileTypeRuntimeDefault,
				},
			},
		})
		return ops
	}

	if c.SecurityContext.AllowPrivilegeEscalation == nil {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  basePath + "/securityContext/allowPrivilegeEscalation",
			Value: false,
		})
	}

	if c.SecurityContext.Capabilities == nil {
		ops = append(ops, patchOp{
			Op:   "add",
			Path: basePath + "/securityContext/capabilities",
			Value: &corev1.Capabilities{
				Drop: []corev1.Capability{"ALL"},
			},
		})
	} else if len(c.SecurityContext.Capabilities.Drop) == 0 {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  basePath + "/securityContext/capabilities/drop",
			Value: []corev1.Capability{"ALL"},
		})
	}

	if c.SecurityContext.SeccompProfile == nil {
		ops = append(ops, patchOp{
			Op:   "add",
			Path: basePath + "/securityContext/seccompProfile",
			Value: &corev1.SeccompProfile{
				Type: corev1.SeccompProfileTypeRuntimeDefault,
			},
		})
	}

	return ops
}

// UPF: domyślne porty (PFCP + GTP-U)
func ensureUpfDefaultPorts(spec *corev1.PodSpec, containersPath string) []patchOp {
	var ops []patchOp
	if len(spec.Containers) == 0 {
		return ops
	}

	idx := -1
	for i, c := range spec.Containers {
		if c.Name == "upf" {
			idx = i
			break
		}
	}
	if idx < 0 {
		idx = 0
	}
	c := spec.Containers[idx]

	const (
		pfcpPort = int32(8805)
		gtpuPort = int32(2152)
	)

	hasPfcp := false
	hasGtpu := false
	for _, p := range c.Ports {
		if p.ContainerPort == pfcpPort {
			hasPfcp = true
		}
		if p.ContainerPort == gtpuPort {
			hasGtpu = true
		}
	}

	portsPath := fmt.Sprintf("%s/%d/ports", containersPath, idx)

	if len(c.Ports) == 0 {
		var newPorts []corev1.ContainerPort
		if !hasPfcp {
			newPorts = append(newPorts, corev1.ContainerPort{
				Name:          "pfcp",
				ContainerPort: pfcpPort,
				Protocol:      corev1.ProtocolUDP,
			})
		}
		if !hasGtpu {
			newPorts = append(newPorts, corev1.ContainerPort{
				Name:          "gtpu",
				ContainerPort: gtpuPort,
				Protocol:      corev1.ProtocolUDP,
			})
		}
		if len(newPorts) > 0 {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  portsPath,
				Value: newPorts,
			})
		}
	} else {
		if !hasPfcp {
			ops = append(ops, patchOp{
				Op:   "add",
				Path: portsPath + "/-",
				Value: corev1.ContainerPort{
					Name:          "pfcp",
					ContainerPort: pfcpPort,
					Protocol:      corev1.ProtocolUDP,
				},
			})
		}
		if !hasGtpu {
			ops = append(ops, patchOp{
				Op:   "add",
				Path: portsPath + "/-",
				Value: corev1.ContainerPort{
					Name:          "gtpu",
					ContainerPort: gtpuPort,
					Protocol:      corev1.ProtocolUDP,
				},
			})
		}
	}

	return ops
}

// Tcpdump sidecar: wspólna funkcja dla Poda i Template
func injectTcpdumpSidecar(spec *corev1.PodSpec, containersPath, volumesPath string, ann map[string]string) []patchOp {
	var ops []patchOp

	sidecar := buildTcpdumpContainer(ann)

	// dodaj kontener
	if len(spec.Containers) == 0 {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  containersPath,
			Value: []corev1.Container{sidecar},
		})
	} else {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  containersPath + "/-",
			Value: sidecar,
		})
	}

	// volume pod /data
	hasVolume := false
	for _, v := range spec.Volumes {
		if v.Name == "tcpdump-data" {
			hasVolume = true
			break
		}
	}
	if !hasVolume {
		vol := corev1.Volume{
			Name: "tcpdump-data",
			VolumeSource: corev1.VolumeSource{
				EmptyDir: &corev1.EmptyDirVolumeSource{},
			},
		}
		if len(spec.Volumes) == 0 {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  volumesPath,
				Value: []corev1.Volume{vol},
			})
		} else {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  volumesPath + "/-",
				Value: vol,
			})
		}
	}

	return ops
}

func buildTcpdumpContainer(ann map[string]string) corev1.Container {
	envs := []corev1.EnvVar{
		{Name: "UPF_SLICE_ID", Value: ann[sliceIdAnnotation]},
		{Name: "UPF_SST", Value: ann[sstAnnotation]},
		{Name: "UPF_SD", Value: ann[sdAnnotation]},
		{Name: "UPF_DNN", Value: ann[dnnAnnotation]},
		{Name: "UPF_UE_POOL_CIDR", Value: ann[uePoolCidrAnnotation]},
		{Name: "UPF_N6_CIDR", Value: ann[n6CidrAnnotation]},
	}

	return corev1.Container{
		Name:  "tcpdump-sidecar",
		Image: tcpdumpImage,
		Args: []string{
			"-i", "any",
			"-w", "/data/trace.pcap",
		},
		Env: envs,
		SecurityContext: &corev1.SecurityContext{
			AllowPrivilegeEscalation: boolPtr(false),
			Capabilities: &corev1.Capabilities{
				Drop: []corev1.Capability{"ALL"},
				Add:  []corev1.Capability{"NET_ADMIN", "NET_RAW"},
			},
			SeccompProfile: &corev1.SeccompProfile{
				Type: corev1.SeccompProfileTypeRuntimeDefault,
			},
		},
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(defaultReqCPU),
				corev1.ResourceMemory: resource.MustParse(defaultReqMemory),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse(defaultLimCPU),
				corev1.ResourceMemory: resource.MustParse(defaultLimMemory),
			},
		},
		VolumeMounts: []corev1.VolumeMount{
			{
				Name:      "tcpdump-data",
				MountPath: "/data",
			},
		},
	}
}

// --------- VALIDATING: Pod / Workload / Service ---------

func validatePod(raw []byte, namespace string, clientset kubernetes.Interface) field.ErrorList {
    pod := &corev1.Pod{}
    if _, _, err := deserializer.Decode(raw, nil, pod); err != nil {
        return field.ErrorList{
            field.Invalid(field.NewPath("kind"), "Pod", fmt.Sprintf("decode pod: %v", err)),
        }
    }

    ctx := context.Background()
    shouldHandle, nsObj, err := shouldHandleNamespace(ctx, clientset, namespace)
    if err != nil {
        return field.ErrorList{
            field.Invalid(field.NewPath("metadata", "namespace"), namespace, err.Error()),
        }
    }
    if !shouldHandle {
        return nil
    }

    var allErrs field.ErrorList

    // główna walidacja kontenerów (rejestry, securityContext, zasoby itd.)
    for i, c := range pod.Spec.Containers {
        fp := field.NewPath("spec", "containers").Index(i)
        allErrs = append(allErrs, validateContainer(&c, fp, nsObj)...)
    }
    for i, c := range pod.Spec.InitContainers {
        fp := field.NewPath("spec", "initContainers").Index(i)
        allErrs = append(allErrs, validateContainer(&c, fp, nsObj)...)
    }

    // hostPath
    allErrs = append(allErrs,
        validateHostPathVolumes(pod, field.NewPath("spec", "volumes"), nsObj)...)

    // anotacje związane z portami / siecią (ogólne mechanizmy)
    if pod.Annotations != nil {
        // 1) wymagane porty na Podzie (ogólny mechanizm)
        if rawPorts := strings.TrimSpace(pod.Annotations[requiredPortsAnnotation]); rawPorts != "" {
            ports, err := parsePortList(rawPorts)
            if err != nil {
                allErrs = append(allErrs, field.Invalid(
                    field.NewPath("metadata", "annotations", requiredPortsAnnotation),
                    rawPorts,
                    err.Error(),
                ))
            } else {
                allErrs = append(allErrs,
                    ensurePortsPresent(ports, pod.Spec.Containers,
                        field.NewPath("spec", "containers"))...)
            }
        }

        // 2) opcjonalna walidacja IP z anotacji CNI (k8s.v1.cni.cncf.io/networks)
        if strings.ToLower(pod.Annotations[validateNetworksAnno]) == "true" {
            if nets := pod.Annotations["k8s.v1.cni.cncf.io/networks"]; strings.TrimSpace(nets) != "" {
                allErrs = append(allErrs,
                    validateNetworks(
                        nets,
                        field.NewPath("metadata", "annotations", "k8s.v1.cni.cncf.io/networks"),
                    )...)
            }
        }
    }

    // 3) specjalna walidacja anotacji 5g.kkarczmarek.dev/networks dla UPF
    if pod.Labels != nil && pod.Labels[nfLabelKey] == "upf" {
        allErrs = append(allErrs, validateUPFNetworks(pod)...)
    }

    return allErrs
}

func validateWorkload(raw []byte, namespace, kind string, clientset kubernetes.Interface) field.ErrorList {
	var tpl *corev1.PodTemplateSpec

	switch kind {
	case "Deployment":
		obj := &appsv1.Deployment{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return field.ErrorList{
				field.Invalid(field.NewPath("kind"), "Deployment", fmt.Sprintf("decode: %v", err)),
			}
		}
		tpl = &obj.Spec.Template
	case "StatefulSet":
		obj := &appsv1.StatefulSet{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return field.ErrorList{
				field.Invalid(field.NewPath("kind"), "StatefulSet", fmt.Sprintf("decode: %v", err)),
			}
		}
		tpl = &obj.Spec.Template
	case "DaemonSet":
		obj := &appsv1.DaemonSet{}
		if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
			return field.ErrorList{
				field.Invalid(field.NewPath("kind"), "DaemonSet", fmt.Sprintf("decode: %v", err)),
			}
		}
		tpl = &obj.Spec.Template
	default:
		return nil
	}

	ctx := context.Background()
	shouldHandle, nsObj, err := shouldHandleNamespace(ctx, clientset, namespace)
	if err != nil {
		return field.ErrorList{
			field.Invalid(field.NewPath("metadata", "namespace"), namespace, err.Error()),
		}
	}
	if !shouldHandle {
		return nil
	}

	var allErrs field.ErrorList

	for i, c := range tpl.Spec.Containers {
		fp := field.NewPath("spec", "template", "spec", "containers").Index(i)
		allErrs = append(allErrs, validateContainer(&c, fp, nsObj)...)
	}
	for i, c := range tpl.Spec.InitContainers {
		fp := field.NewPath("spec", "template", "spec", "initContainers").Index(i)
		allErrs = append(allErrs, validateContainer(&c, fp, nsObj)...)
	}

	// hostPath
	allErrs = append(allErrs, validateHostPathVolumesTemplate(tpl,
		field.NewPath("spec", "template", "spec", "volumes"), nsObj)...)

	// wymagane porty na szablonie
	if tpl.Annotations != nil {
		rawPorts := strings.TrimSpace(tpl.Annotations[requiredPortsAnnotation])
		if rawPorts != "" {
			ports, err := parsePortList(rawPorts)
			if err != nil {
				allErrs = append(allErrs, field.Invalid(
					field.NewPath("spec", "template", "metadata", "annotations", requiredPortsAnnotation),
					rawPorts,
					err.Error(),
				))
			} else {
				allErrs = append(allErrs,
					ensurePortsPresent(ports, tpl.Spec.Containers,
						field.NewPath("spec", "template", "spec", "containers"))...)
			}
		}

		if strings.ToLower(tpl.Annotations[validateNetworksAnno]) == "true" {
			if nets := tpl.Annotations["k8s.v1.cni.cncf.io/networks"]; strings.TrimSpace(nets) != "" {
				allErrs = append(allErrs,
					validateNetworks(nets,
						field.NewPath("spec", "template", "metadata", "annotations", "k8s.v1.cni.cncf.io/networks"))...)
			}
		}
	}

	return allErrs
}

func validateService(raw []byte, namespace string, clientset kubernetes.Interface) field.ErrorList {
	svc := &corev1.Service{}
	if _, _, err := deserializer.Decode(raw, nil, svc); err != nil {
		return field.ErrorList{
			field.Invalid(field.NewPath("kind"), "Service", fmt.Sprintf("decode service: %v", err)),
		}
	}

	ctx := context.Background()
	shouldHandle, _, err := shouldHandleNamespace(ctx, clientset, namespace)
	if err != nil {
		return field.ErrorList{
			field.Invalid(field.NewPath("metadata", "namespace"), namespace, err.Error()),
		}
	}
	if !shouldHandle {
		return nil
	}

	var allErrs field.ErrorList

	// service IP z anotacji
	if svc.Annotations != nil {
		if val, ok := svc.Annotations[serviceIPAnnotation]; ok {
			ipStr := strings.TrimSpace(val)
			if ipStr != "" {
				ip := net.ParseIP(ipStr)
				if ip == nil {
					allErrs = append(allErrs, field.Invalid(
						field.NewPath("metadata", "annotations", serviceIPAnnotation),
						val,
						"not a valid IP address",
					))
				} else if dataPlaneCIDR != "" {
					_, cidrNet, err := net.ParseCIDR(dataPlaneCIDR)
					if err == nil && !cidrNet.Contains(ip) {
						allErrs = append(allErrs, field.Forbidden(
							field.NewPath("metadata", "annotations", serviceIPAnnotation),
							fmt.Sprintf("service IP %s must be inside %s", ipStr, dataPlaneCIDR),
						))
					}
				}
			}
		}

		if rawPorts := strings.TrimSpace(svc.Annotations[requiredPortsAnnotation]); rawPorts != "" {
			ports, err := parsePortList(rawPorts)
			if err != nil {
				allErrs = append(allErrs, field.Invalid(
					field.NewPath("metadata", "annotations", requiredPortsAnnotation),
					rawPorts,
					err.Error(),
				))
			} else {
				for _, p := range ports {
					found := false
					for _, sp := range svc.Spec.Ports {
						if sp.Port == p {
							found = true
							break
						}
					}
					if !found {
						allErrs = append(allErrs, field.Forbidden(
							field.NewPath("spec", "ports"),
							fmt.Sprintf("service must expose port %d (required by %s)", p, requiredPortsAnnotation),
						))
					}
				}
			}
		}
	}
	return allErrs
}

// Walidacja pojedynczego kontenera
func validateContainer(c *corev1.Container, fp *field.Path, ns *corev1.Namespace) field.ErrorList {
	var errs field.ErrorList

	// zakaz :latest (opcjonalny, sterowany env)
	if denyLatestTag {
		if strings.HasSuffix(c.Image, ":latest") || !strings.Contains(c.Image, ":") {
			errs = append(errs, field.Forbidden(fp.Child("image"),
				"image tag ':latest' (lub brak taga) jest zabroniony – użyj konkretnej wersji"))
		}
	}

	// NET_ADMIN / NET_RAW tylko w namespace z allow-netadmin=true
	if c.SecurityContext != nil && c.SecurityContext.Capabilities != nil {
		for _, cap := range c.SecurityContext.Capabilities.Add {
			if cap == "NET_ADMIN" || cap == "NET_RAW" {
				if ns.Labels == nil || strings.ToLower(ns.Labels[allowNetAdminNsLabel]) != "true" {
					errs = append(errs, field.Forbidden(
						fp.Child("securityContext", "capabilities", "add"),
						"NET_ADMIN / NET_RAW wymaga labela namespace'u allow-netadmin=true",
					))
				}
			}
		}
	}

	// Wymóg zasobów w free5gc – CPU i pamięć
	if ns.Name == "free5gc" {
		res := c.Resources
		if res.Requests == nil || res.Limits == nil ||
			res.Requests.Cpu() == nil || res.Requests.Memory() == nil ||
			res.Limits.Cpu() == nil || res.Limits.Memory() == nil {
			errs = append(errs, field.Forbidden(
				fp.Child("resources"),
				"kontenery w namespace 'free5gc' muszą mieć ustawione CPU/memory requests i limits",
			))
		}
	}

	return errs
}

// hostPath na Podzie
func validateHostPathVolumes(pod *corev1.Pod, fp *field.Path, ns *corev1.Namespace) field.ErrorList {
	var errs field.ErrorList
	for i, v := range pod.Spec.Volumes {
		if v.HostPath == nil {
			continue
		}
		if ns.Labels == nil || strings.ToLower(ns.Labels[allowHostPathNsLabel]) != "true" {
			errs = append(errs, field.Forbidden(
				fp.Index(i).Child("hostPath"),
				fmt.Sprintf("hostPath %q wymaga labela namespace'u %s=true", v.HostPath.Path, allowHostPathNsLabel),
			))
		}
	}
	return errs
}

// hostPath na PodTemplate
func validateHostPathVolumesTemplate(tpl *corev1.PodTemplateSpec, fp *field.Path, ns *corev1.Namespace) field.ErrorList {
	var errs field.ErrorList
	for i, v := range tpl.Spec.Volumes {
		if v.HostPath == nil {
			continue
		}
		if ns.Labels == nil || strings.ToLower(ns.Labels[allowHostPathNsLabel]) != "true" {
			errs = append(errs, field.Forbidden(
				fp.Index(i).Child("hostPath"),
				fmt.Sprintf("hostPath %q wymaga labela namespace'u %s=true", v.HostPath.Path, allowHostPathNsLabel),
			))
		}
	}
	return errs
}

// Walidacja IP z anotacji CNI (np. dla interfejsów dataplane)
func validateNetworks(raw string, fp *field.Path) field.ErrorList {
	var errs field.ErrorList
	if dataPlaneCIDR == "" {
		return nil
	}
	_, cidrNet, err := net.ParseCIDR(dataPlaneCIDR)
	if err != nil {
		return nil
	}

	matches := ipCidrRegex.FindAllString(raw, -1)
	for _, m := range matches {
		parts := strings.SplitN(m, "/", 2)
		if len(parts) != 2 {
			continue
		}
		ip := net.ParseIP(parts[0])
		if ip == nil {
			continue
		}
		if !cidrNet.Contains(ip) {
			errs = append(errs, field.Forbidden(
				fp,
				fmt.Sprintf("adres %s z anotacji CNI nie należy do dozwolonej puli %s", m, dataPlaneCIDR),
			))
		}
	}

	return errs
}

func validateUPFNetworks(pod *corev1.Pod) field.ErrorList {
    var allErrs field.ErrorList

    if pod.Annotations == nil {
        return nil
    }

    raw := strings.TrimSpace(pod.Annotations[upfNetworksAnnotation])
    if raw == "" {
        return nil
    }

    // spodziewany format: "n6-net@10.100.10.5/24,n3-net@10.100.20.5/24"
    entries := strings.Split(raw, ",")
    for _, e := range entries {
        e = strings.TrimSpace(e)
        if e == "" {
            continue
        }

        parts := strings.Split(e, "@")
        if len(parts) != 2 {
            allErrs = append(allErrs, field.Invalid(
                field.NewPath("metadata", "annotations", upfNetworksAnnotation),
                raw,
                "each entry must be in form <name>@<ip>/<mask>, e.g. n6-net@10.100.10.5/24",
            ))
            continue
        }

        ipWithMask := strings.TrimSpace(parts[1])
        ip, _, err := net.ParseCIDR(ipWithMask)
        if err != nil {
            allErrs = append(allErrs, field.Invalid(
                field.NewPath("metadata", "annotations", upfNetworksAnnotation),
                ipWithMask,
                "must be a valid CIDR, e.g. 10.100.10.5/24",
            ))
            continue
        }

        if dataPlaneCIDR != "" {
            _, dataNet, err2 := net.ParseCIDR(dataPlaneCIDR)
            if err2 == nil && !dataNet.Contains(ip) {
                allErrs = append(allErrs, field.Forbidden(
                    field.NewPath("metadata", "annotations", upfNetworksAnnotation),
                    fmt.Sprintf("network IP %s must be inside %s", ip.String(), dataPlaneCIDR),
                ))
            }
        }
    }

    return allErrs
}


// --------- WSPÓLNE NARZĘDZIA ---------

func shouldHandleNamespace(ctx context.Context, clientset kubernetes.Interface, namespace string) (bool, *corev1.Namespace, error) {
	ns, err := clientset.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		return false, nil, fmt.Errorf("get namespace %q: %w", namespace, err)
	}
	if ns.Labels == nil {
		return false, ns, nil
	}
	return strings.ToLower(ns.Labels[admissionLabelKey]) == "true", ns, nil
}

func isFree5gcWorkload(meta metav1.ObjectMeta, ns string) bool {
	if meta.Labels[projectLabelKey] == projectLabelValue {
		return true
	}
	if meta.Labels[partOfLabelKey] == partOfLabelValue {
		return true
	}
	return ns == "free5gc"
}

func isUpfPod(pod *corev1.Pod) bool {
	if pod == nil {
		return false
	}
	tpl := &corev1.PodTemplateSpec{
		ObjectMeta: pod.ObjectMeta,
		Spec:       pod.Spec,
	}
	return isUpfPodTemplate(tpl)
}

func isUpfPodTemplate(t *corev1.PodTemplateSpec) bool {
	if t == nil {
		return false
	}
	if t.Labels[nfLabelKey] == "upf" {
		return true
	}
	if t.Labels["app.kubernetes.io/name"] == "free5gc-upf" {
		return true
	}
	for _, c := range t.Spec.Containers {
		if c.Name == "upf" {
			return true
		}
	}
	return false
}

func isTcpdumpEnabled(ann map[string]string) bool {
	if ann == nil {
		return false
	}
	v := strings.ToLower(ann[tcpdumpEnabledAnnotation])
	return v == "true" || v == "1" || v == "yes" || v == "on"
}

func parsePortList(raw string) ([]int32, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	splitFn := func(r rune) bool {
		return r == ',' || r == ';' || r == ' ' || r == '\t'
	}
	parts := strings.FieldsFunc(raw, splitFn)
	var ports []int32
	for _, p := range parts {
		if p == "" {
			continue
		}
		v, err := strconv.ParseInt(p, 10, 32)
		if err != nil {
			return nil, fmt.Errorf("invalid port %q", p)
		}
		if v <= 0 || v > 65535 {
			return nil, fmt.Errorf("port out of range: %d", v)
		}
		ports = append(ports, int32(v))
	}
	return ports, nil
}

func ensurePortsPresent(ports []int32, containers []corev1.Container, fp *field.Path) field.ErrorList {
	var errs field.ErrorList
	for _, port := range ports {
		if !hasContainerPort(containers, port) {
			errs = append(errs, field.Forbidden(
				fp.Child("ports"),
				fmt.Sprintf("wymagany port %d (z %s) nie jest wystawiony przez żaden kontener", port, requiredPortsAnnotation),
			))
		}
	}
	return errs
}

func hasContainerPort(containers []corev1.Container, port int32) bool {
	for _, c := range containers {
		for _, cp := range c.Ports {
			if cp.ContainerPort == port {
				return true
			}
		}
	}
	return false
}

func escapeJSONPointer(s string) string {
	s = strings.ReplaceAll(s, "~", "~0")
	s = strings.ReplaceAll(s, "/", "~1")
	return s
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvBool(key string, def bool) bool {
	v := strings.ToLower(os.Getenv(key))
	if v == "true" || v == "1" || v == "yes" || v == "on" {
		return true
	}
	if v == "false" || v == "0" || v == "no" || v == "off" {
		return false
	}
	return def
}

func boolPtr(b bool) *bool {
	return &b
}

// mała pomocnicza, żeby mieć jakiś timeout przy wewnętrznych callach (opcjonalnie)
func ctxWithTimeout() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}
