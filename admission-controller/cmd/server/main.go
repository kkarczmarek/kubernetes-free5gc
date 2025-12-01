package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/util/validation/field"
	types "k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

var (
	scheme       = runtime.NewScheme()
	codecs       = serializer.NewCodecFactory(scheme)
	deserializer = codecs.UniversalDeserializer()

	defaultCPURequest = getenv("DEFAULT_CPU_REQUEST", "50m")
	defaultMemRequest = getenv("DEFAULT_MEM_REQUEST", "128Mi")
	defaultCPULimit   = getenv("DEFAULT_CPU_LIMIT", "500m")
	defaultMemLimit   = getenv("DEFAULT_MEM_LIMIT", "512Mi")

	projectLabelKey   = "project"
	partOfLabelKey    = "app.kubernetes.io/part-of"
	projectLabelValue = getenv("PROJECT_LABEL_VALUE", "free5gc")
	partOfLabelValue  = getenv("PARTOF_LABEL_VALUE", "free5gc")

	free5gcNamespace  = getenv("FREE5GC_NAMESPACE", "free5gc")
	dataPlaneCIDR     = getenv("DATA_CIDR", "192.168.50.0/24")
	allowedRegistries = strings.Split(getenv("ALLOWED_REGISTRIES", "ghcr.io,public.ecr.aws,docker.io"), ",")

	denyLatestTag   = getenv("DENY_LATEST_TAG", "true") == "true"
	tcpdumpImage     = getenv("TCPDUMP_IMAGE", "docker.io/corfr/tcpdump:latest")
)

const tcpdumpContainerName = "tcpdump-sidecar"

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func sanitizeLabelValue(v string) string {
    // K8s label value nie może mieć '/', więc zamieniamy go na '-'.
    // Przykład: "10.60.0.0/24" -> "10.60.0.0-24"
    return strings.ReplaceAll(v, "/", "-")
}

func writeReview(w http.ResponseWriter, ar admissionv1.AdmissionReview) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(ar)
}

func toError(ar *admissionv1.AdmissionReview, uid types.UID, err error) {
	ar.Response = &admissionv1.AdmissionResponse{
		UID:     uid,
		Allowed: false,
		Result:  &metav1.Status{Message: err.Error()},
	}
}

func main() {
	certFile := getenv("TLS_CERT_FILE", "/tls/tls.crt")
	keyFile := getenv("TLS_KEY_FILE", "/tls/tls.key")

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})
	mux.HandleFunc("/mutate", handleMutate)
	mux.HandleFunc("/validate", handleValidate)

	srv := &http.Server{
		Addr:    ":8443",
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("starting webhook server on :8443")
	if err := srv.ListenAndServeTLS(certFile, keyFile); err != nil {
		log.Fatalf("server: %v", err)
	}
}

// ---------------- MUTATE ----------------

func handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var review admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &review); err != nil {
		http.Error(w, fmt.Sprintf("decode: %v", err), http.StatusBadRequest)
		return
	}
	req := review.Request
	resp := &admissionv1.AdmissionResponse{UID: req.UID, Allowed: true}

	switch req.Kind.Kind {
	case "Pod":
		if patch, err := mutatePod(req.Object.Raw); err != nil {
			toError(&review, req.UID, err)
		} else if len(patch) > 0 {
			pt := admissionv1.PatchTypeJSONPatch
			resp.PatchType = &pt
			resp.Patch = patch
		}
	case "Deployment", "StatefulSet", "DaemonSet":
		if patch, err := mutateWorkload(req.Object.Raw, req.Kind.Kind); err != nil {
			toError(&review, req.UID, err)
		} else if len(patch) > 0 {
			pt := admissionv1.PatchTypeJSONPatch
			resp.PatchType = &pt
			resp.Patch = patch
		}
	}

	review.Response = resp
	writeReview(w, review)
}

type patchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func mutatePodWithTcpdump(pod *corev1.Pod, ops []patchOp) []patchOp {
	// Używamy isUpfPodTemplate, ale "opakowujemy" Pod w PodTemplateSpec
	template := &corev1.PodTemplateSpec{
		ObjectMeta: pod.ObjectMeta,
		Spec:       pod.Spec,
	}

	if !isUpfPodTemplate(template) {
		return ops
	}

	annPath := "/metadata/annotations"

	// Upewniamy się, że anotacje istnieją
	if pod.Annotations == nil {
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  annPath,
			Value: map[string]interface{}{},
		})
	}

	// Włączanie tcpdumpa tylko jeśli explicite ustawiono flagę
	if pod.Annotations["5g.kkarczmarek.dev/tcpdump-enabled"] != "true" {
		return ops
	}

	// Jeśli ten Pod nie ma jeszcze sidecara, wstrzykujemy go
	if !hasTcpdumpContainer(&pod.Spec) {
		sidecar := buildTcpdumpContainer(pod.Annotations)

		volPath := "/spec/volumes"

		// jeśli nie ma volumes, dodajemy pustą listę
		if len(pod.Spec.Volumes) == 0 {
			ops = append(ops, patchOp{
				Op:    "add",
				Path:  volPath,
				Value: []interface{}{},
			})
		}

		// dodajemy kontener tcpdump-sidecar na końcu listy containers
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  "/spec/containers/-",
			Value: sidecar,
		})

		// i volume typu emptyDir na dane tcpdumpa
		tcpdumpVol := map[string]interface{}{
			"name": "tcpdump-data",
			"emptyDir": map[string]interface{}{},
		}
		ops = append(ops, patchOp{
			Op:    "add",
			Path:  volPath + "/-",
			Value: tcpdumpVol,
		})
	}

	return ops
}

func mutatePod(raw []byte) ([]byte, error) {
	obj := &corev1.Pod{}
	if _, _, err := deserializer.Decode(raw, nil, obj); err != nil {
		return nil, fmt.Errorf("decode pod: %w", err)
	}
	var ops []patchOp

	// Upewnij się, że mamy mapę labels
	if obj.Labels == nil {
		ops = append(ops, patchOp{"add", "/metadata/labels", map[string]interface{}{}})
	}

	// Domyślne labele projektu (to, co już miałeś)
	if obj.Labels[partOfLabelKey] == "" {
		ops = append(ops, patchOp{"add", "/metadata/labels/" + escape(partOfLabelKey), partOfLabelValue})
	}
	if obj.Labels[projectLabelKey] == "" {
		ops = append(ops, patchOp{"add", "/metadata/labels/" + escape(projectLabelKey), projectLabelValue})
	}

	// 5G slicing:
	// Jeżeli Pod jest częścią free5gc (app.kubernetes.io/part-of=free5gc),
	// to kopiujemy wybrane anotacje do labeli:
	//   - 5g.kkarczmarek.dev/slice-id
	//   - 5g.kkarczmarek.dev/sst
	//   - 5g.kkarczmarek.dev/sd
	//   - 5g.kkarczmarek.dev/dnn
	//   - 5g.kkarczmarek.dev/ue-pool-cidr
	//   - 5g.kkarczmarek.dev/n6-cidr
	if obj.Annotations != nil && obj.Labels[partOfLabelKey] == partOfLabelValue {
			keys := []string{
		"5g.kkarczmarek.dev/slice-id",
		"5g.kkarczmarek.dev/sst",
		"5g.kkarczmarek.dev/sd",
		"5g.kkarczmarek.dev/dnn",
		"5g.kkarczmarek.dev/ue-pool-cidr",
		"5g.kkarczmarek.dev/n6-cidr",
	}
	for _, k := range keys {
		if v, ok := obj.Annotations[k]; ok {
			if obj.Labels[k] == "" {
				value := v
				// dla kluczy kończących się na "-cidr" sanitizujemy wartość,
				// żeby nadawała się na label (bez '/')
				if strings.HasSuffix(k, "-cidr") {
					value = sanitizeLabelValue(v)
				}
				ops = append(ops, patchOp{"add", "/metadata/labels/" + escape(k), value})
			}
		}
	}

	}

	// WAŻNE:
	// NIE ustawiamy już spec.securityContext.runAsNonRoot.
	// Twarde zabezpieczenia robimy tylko na poziomie kontenera (ensureContainers).

	// Kontenery + initContainers
	ops = append(ops, ensureContainers(obj.Spec.Containers, "/spec/containers")...)
	ops = append(ops, ensureContainers(obj.Spec.InitContainers, "/spec/initContainers")...)
	ops = mutatePodWithTcpdump(obj, ops)

	return json.Marshal(ops)
}

func ensureContainers(cs []corev1.Container, base string) []patchOp {
	var ops []patchOp
	for i := range cs {
		scPath := fmt.Sprintf("%s/%d/securityContext", base, i)

		// securityContext {}
		if cs[i].SecurityContext == nil {
			ops = append(ops, patchOp{"add", scPath, map[string]interface{}{}})
		}

		// allowPrivilegeEscalation: false (tylko gdy brak)
		if cs[i].SecurityContext == nil || cs[i].SecurityContext.AllowPrivilegeEscalation == nil {
			ops = append(ops, patchOp{"add", scPath + "/allowPrivilegeEscalation", false})
		}

		// capabilities {} -> drop: ["ALL"] (gdy brak)
		if cs[i].SecurityContext == nil || cs[i].SecurityContext.Capabilities == nil {
			ops = append(ops, patchOp{"add", scPath + "/capabilities", map[string]interface{}{}})
		}
		if cs[i].SecurityContext == nil || cs[i].SecurityContext.Capabilities == nil || len(cs[i].SecurityContext.Capabilities.Drop) == 0 {
			ops = append(ops, patchOp{"add", scPath + "/capabilities/drop", []string{"ALL"}})
		}

		// seccompProfile {} -> type: RuntimeDefault (gdy brak)
		if cs[i].SecurityContext == nil || cs[i].SecurityContext.SeccompProfile == nil {
			ops = append(ops, patchOp{"add", scPath + "/seccompProfile", map[string]interface{}{}})
			ops = append(ops, patchOp{"add", scPath + "/seccompProfile/type", "RuntimeDefault"})
		} else if cs[i].SecurityContext.SeccompProfile.Type == "" {
			ops = append(ops, patchOp{"add", scPath + "/seccompProfile/type", "RuntimeDefault"})
		}

		// resources/requests/limits (utwórz brakujące obiekty)
		resPath := fmt.Sprintf("%s/%d/resources", base, i)
		if cs[i].Resources.Requests == nil && cs[i].Resources.Limits == nil {
			ops = append(ops, patchOp{"add", resPath, map[string]interface{}{}})
		}
		if cs[i].Resources.Requests == nil {
			ops = append(ops, patchOp{"add", resPath + "/requests", map[string]interface{}{}})
		}
		if cs[i].Resources.Limits == nil {
			ops = append(ops, patchOp{"add", resPath + "/limits", map[string]interface{}{}})
		}

		// domyślne wartości gdy 0
		if cs[i].Resources.Requests.Cpu().IsZero() {
			ops = append(ops, patchOp{"add", resPath + "/requests/cpu", defaultCPURequest})
		}
		if cs[i].Resources.Requests.Memory().IsZero() {
			ops = append(ops, patchOp{"add", resPath + "/requests/memory", defaultMemRequest})
		}
		if cs[i].Resources.Limits.Cpu().IsZero() {
			ops = append(ops, patchOp{"add", resPath + "/limits/cpu", defaultCPULimit})
		}
		if cs[i].Resources.Limits.Memory().IsZero() {
			ops = append(ops, patchOp{"add", resPath + "/limits/memory", defaultMemLimit})
		}
	}
	return ops
}

func isUpfPodTemplate(t *corev1.PodTemplateSpec) bool {
	if t == nil {
		return false
	}

	// NF z labela nf=upf
	if t.Labels["nf"] == "upf" {
		return true
	}

	// albo z app.kubernetes.io/name
	if t.Labels["app.kubernetes.io/name"] == "free5gc-upf" {
		return true
	}

	return false
}

func hasTcpdumpContainer(podSpec *corev1.PodSpec) bool {
	if podSpec == nil {
		return false
	}
	for _, c := range podSpec.Containers {
		if c.Name == tcpdumpContainerName {
			return true
		}
	}
	return false
}

func buildTcpdumpContainer(ann map[string]string) map[string]interface{} {
	env := []map[string]interface{}{}

	// helper do dodawania env z anotacji
	addEnv := func(envName, annKey string) {
		if ann == nil {
			return
		}
		if v, ok := ann[annKey]; ok && v != "" {
			env = append(env, map[string]interface{}{
				"name":  envName,
				"value": v,
			})
		}
	}

	// przekazujemy do tcpdump info o slice / adresacji
	addEnv("UPF_SLICE_ID", "5g.kkarczmarek.dev/slice-id")
	addEnv("UPF_SST", "5g.kkarczmarek.dev/sst")
	addEnv("UPF_SD", "5g.kkarczmarek.dev/sd")
	addEnv("UPF_DNN", "5g.kkarczmarek.dev/dnn")
	addEnv("UPF_UE_POOL_CIDR", "5g.kkarczmarek.dev/ue-pool-cidr")
	addEnv("UPF_N6_CIDR", "5g.kkarczmarek.dev/n6-cidr")

	container := map[string]interface{}{
		"name":            tcpdumpContainerName,
		"image":           tcpdumpImage,
		"imagePullPolicy": "IfNotPresent",
		"args": []string{
			"-i", "any",
			"-w", "/data/trace.pcap",
		},
		"securityContext": map[string]interface{}{
			"allowPrivilegeEscalation": false,
			"capabilities": map[string]interface{}{
				"drop": []string{"ALL"},
				"add":  []string{"NET_ADMIN", "NET_RAW"},
			},
			"seccompProfile": map[string]interface{}{
				"type": "RuntimeDefault",
			},
		},
		"volumeMounts": []map[string]interface{}{
			{
				"name":      "tcpdump-data",
				"mountPath": "/data",
			},
		},
		"resources": map[string]interface{}{
			"requests": map[string]interface{}{
				"cpu":    defaultCPURequest,
				"memory": defaultMemRequest,
			},
			"limits": map[string]interface{}{
				"cpu":    defaultCPULimit,
				"memory": defaultMemLimit,
			},
		},
	}

	if len(env) > 0 {
		container["env"] = env
	}

	return container
}

func mutateWorkload(raw []byte, kind string) ([]byte, error) {
	type metaWorkload struct {
		Spec struct {
			Template corev1.PodTemplateSpec `json:"template"`
		} `json:"spec"`
	}
	var wl metaWorkload
	if err := json.Unmarshal(raw, &wl); err != nil {
		return nil, fmt.Errorf("decode %s: %w", kind, err)
	}
	var ops []patchOp

	// Upewnij się, że mamy mapę labels na template
	if wl.Spec.Template.Labels == nil {
		ops = append(ops, patchOp{"add", "/spec/template/metadata/labels", map[string]interface{}{}})
	}

	// Domyślne labele projektu
	if wl.Spec.Template.Labels[partOfLabelKey] == "" {
		ops = append(ops, patchOp{"add", "/spec/template/metadata/labels/" + escape(partOfLabelKey), partOfLabelValue})
	}
	if wl.Spec.Template.Labels[projectLabelKey] == "" {
		ops = append(ops, patchOp{"add", "/spec/template/metadata/labels/" + escape(projectLabelKey), projectLabelValue})
	}

	// 5G slicing na poziomie template:
	// kopiujemy anotacje template → labele template,
	// jeżeli workload jest częścią free5gc.
		if wl.Spec.Template.Annotations != nil && wl.Spec.Template.Labels[partOfLabelKey] == partOfLabelValue {
		keys := []string{
			"5g.kkarczmarek.dev/slice-id",
			"5g.kkarczmarek.dev/sst",
			"5g.kkarczmarek.dev/sd",
			"5g.kkarczmarek.dev/dnn",
			"5g.kkarczmarek.dev/ue-pool-cidr",
			"5g.kkarczmarek.dev/n6-cidr",
		}
		for _, k := range keys {
			if v, ok := wl.Spec.Template.Annotations[k]; ok {
				if wl.Spec.Template.Labels[k] == "" {
					value := v
					if strings.HasSuffix(k, "-cidr") {
						value = sanitizeLabelValue(v)
					}
					ops = append(ops, patchOp{"add", "/spec/template/metadata/labels/" + escape(k), value})
				}
			}
		}
	}


	// WAŻNE:
	// NIE ustawiamy /spec/template/spec/securityContext/runAsNonRoot.
	// To już wyłączyliśmy – tu tylko labele + kontenerowe securityContext.

	ops = append(ops, ensureContainers(wl.Spec.Template.Spec.Containers, "/spec/template/spec/containers")...)
	ops = append(ops, ensureContainers(wl.Spec.Template.Spec.InitContainers, "/spec/template/spec/initContainers")...)

	    // --- UPF: wstrzyknięcie sidecara z tcpdump ---
    if isUpfPodTemplate(&wl.Spec.Template) {
        annPath := "/spec/template/metadata/annotations"

        // upewniamy się, że annotations istnieją w obiekcie (dla poprawnego patcha)
        if wl.Spec.Template.Annotations == nil {
            ops = append(ops, patchOp{
                Op:    "add",
                Path:  annPath,
                Value: map[string]interface{}{},
            })
        }

        // Jeśli chcesz tcpdump tylko gdy explicite włączysz:
        // 5g.kkarczmarek.dev/tcpdump-enabled: "true"
        if wl.Spec.Template.Annotations["5g.kkarczmarek.dev/tcpdump-enabled"] == "true" {
            if !hasTcpdumpContainer(&wl.Spec.Template.Spec) {
                sidecar := buildTcpdumpContainer(wl.Spec.Template.Annotations)

                // upewniamy się, że volumes istnieją
                volPath := "/spec/template/spec/volumes"
                if len(wl.Spec.Template.Spec.Volumes) == 0 {
                    ops = append(ops, patchOp{
                        Op:    "add",
                        Path:  volPath,
                        Value: []interface{}{},
                    })
                }

                // dodajemy kontener tcpdump
                ops = append(ops, patchOp{
                    Op:    "add",
                    Path:  "/spec/template/spec/containers/-",
                    Value: sidecar,
                })

                // i volume, gdzie będzie leżał plik pcap
                tcpdumpVol := map[string]interface{}{
                    "name": "tcpdump-data",
                    "emptyDir": map[string]interface{}{},
                }
                ops = append(ops, patchOp{
                    Op:    "add",
                    Path:  volPath + "/-",
                    Value: tcpdumpVol,
                })
            }
        }
    }


	return json.Marshal(ops)
}


func escape(s string) string {
	return strings.ReplaceAll(s, "/", "~1")
}

// ---------------- VALIDATE ----------------

func handleValidate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var review admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &review); err != nil {
		http.Error(w, fmt.Sprintf("decode: %v", err), http.StatusBadRequest)
		return
	}
	req := review.Request
	resp := &admissionv1.AdmissionResponse{UID: req.UID, Allowed: true}

	cfg, err := rest.InClusterConfig()
	if err != nil {
		toError(&review, req.UID, fmt.Errorf("in-cluster config: %w", err))
		writeReview(w, review)
		return
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		toError(&review, req.UID, fmt.Errorf("clientset: %w", err))
		writeReview(w, review)
		return
	}

	var allErrs field.ErrorList

	switch req.Kind.Kind {
	case "Pod":
		allErrs = validatePod(req.Object.Raw, req.Namespace, client)
	case "Deployment", "StatefulSet", "DaemonSet":
		allErrs = validateWorkload(req.Object.Raw, req.Kind.Kind, req.Namespace, client)
	}

	if len(allErrs) > 0 {
		resp.Allowed = false
		resp.Result = &metav1.Status{Message: allErrs.ToAggregate().Error()}
	}
	review.Response = resp
	writeReview(w, review)
}

func validatePod(raw []byte, ns string, cs *kubernetes.Clientset) field.ErrorList {
	p := &corev1.Pod{}
	_, _, err := deserializer.Decode(raw, nil, p)
	if err != nil {
		return field.ErrorList{field.Invalid(field.NewPath("pod"), "", fmt.Sprintf("decode: %v", err))}
	}
	var errs field.ErrorList

	if p.Labels[partOfLabelKey] == partOfLabelValue && ns != free5gcNamespace {
		errs = append(errs, field.Forbidden(field.NewPath("metadata", "namespace"), fmt.Sprintf("must be %q", free5gcNamespace)))
	}

	if p.Spec.HostNetwork {
		errs = append(errs, field.Forbidden(field.NewPath("spec", "hostNetwork"), "hostNetwork not allowed"))
	}

	cpath := field.NewPath("spec", "containers")
	for i := range p.Spec.Containers {
		errs = append(errs, validateContainer(&p.Spec.Containers[i], cpath.Index(i), ns, cs)...)
	}
	icpath := field.NewPath("spec", "initContainers")
	for i := range p.Spec.InitContainers {
		errs = append(errs, validateContainer(&p.Spec.InitContainers[i], icpath.Index(i), ns, cs)...)
	}
// UWAGA:
	// Tymczasowo wyłączamy walidację sieci Multus (k8s.v1.cni.cncf.io/networks),
	// żeby nie blokować istniejących konfiguracji free5gc / UERANSIM.
	// Jeżeli będziemy chcieli znowu weryfikować CIDR, łatwo będzie odkomentować.

//	if nets := p.Annotations["k8s.v1.cni.cncf.io/networks"]; len(nets) > 0 {
//		errs = append(errs, validateNetworks(nets, field.NewPath("metadata", "annotations", "k8s.v1.cni.cncf.io/networks"))...)
//	}

	return errs
}

func validateWorkload(raw []byte, kind, ns string, cs *kubernetes.Clientset) field.ErrorList {
	type metaWorkload struct {
		Spec struct {
			Template corev1.PodTemplateSpec `json:"template"`
		} `json:"spec"`
	}
	var wl metaWorkload
	if err := json.Unmarshal(raw, &wl); err != nil {
		return field.ErrorList{field.Invalid(field.NewPath(kind), "", fmt.Sprintf("decode: %v", err))}
	}
	var errs field.ErrorList

	if wl.Spec.Template.Labels[partOfLabelKey] == partOfLabelValue && ns != free5gcNamespace {
		errs = append(errs, field.Forbidden(field.NewPath("metadata", "namespace"), fmt.Sprintf("must be %q", free5gcNamespace)))
	}

	cpath := field.NewPath("spec", "template", "spec", "containers")
	for i := range wl.Spec.Template.Spec.Containers {
		errs = append(errs, validateContainer(&wl.Spec.Template.Spec.Containers[i], cpath.Index(i), ns, cs)...)
	}
	icpath := field.NewPath("spec", "template", "spec", "initContainers")
	for i := range wl.Spec.Template.Spec.InitContainers {
		errs = append(errs, validateContainer(&wl.Spec.Template.Spec.InitContainers[i], icpath.Index(i), ns, cs)...)
	}

	if wl.Spec.Template.Spec.HostNetwork {
		errs = append(errs, field.Forbidden(field.NewPath("spec", "template", "spec", "hostNetwork"), "hostNetwork not allowed"))
	}
// UWAGA:
	// Tymczasowo wyłączamy walidację Multusa na poziomie template.
//	if nets := wl.Spec.Template.Annotations["k8s.v1.cni.cncf.io/networks"]; len(nets) > 0 {
//		errs = append(errs, validateNetworks(nets, field.NewPath("spec", "template", "metadata", "annotations", "k8s.v1.cni.cncf.io/networks"))...)
//	}

	return errs
}

func validateContainer(c *corev1.Container, fp *field.Path, ns string, cs *kubernetes.Clientset) field.ErrorList {
	var errs field.ErrorList

	reqs := c.Resources.Requests
	lims := c.Resources.Limits
	if reqs.Cpu().IsZero() || reqs.Memory().IsZero() || lims.Cpu().IsZero() || lims.Memory().IsZero() {
		errs = append(errs, field.Required(fp.Child("resources"), "requests/limits cpu+memory required"))
	} else {
		if lims.Cpu().Cmp(*reqs.Cpu()) < 0 {
			errs = append(errs, field.Invalid(fp.Child("resources", "limits", "cpu"), lims.Cpu().String(), "must be >= requests.cpu"))
		}
		if lims.Memory().Cmp(*reqs.Memory()) < 0 {
			errs = append(errs, field.Invalid(fp.Child("resources", "limits", "memory"), lims.Memory().String(), "must be >= requests.memory"))
		}
	}

	if img := c.Image; img != "" {
		if denyLatestTag && (strings.HasSuffix(img, ":latest") || !strings.Contains(img, ":")) {
			errs = append(errs, field.Forbidden(fp.Child("image"), "image tag ':latest' is forbidden; use pinned tag or digest"))
		}
		if !isAllowedRegistry(img) {
			errs = append(errs, field.Forbidden(fp.Child("image"), "image registry not allowed"))
		}
	}

	if c.SecurityContext != nil && c.SecurityContext.Privileged != nil && *c.SecurityContext.Privileged {
		errs = append(errs, field.Forbidden(fp.Child("securityContext", "privileged"), "privileged is forbidden"))
	}

	if c.SecurityContext != nil && c.SecurityContext.Capabilities != nil && len(c.SecurityContext.Capabilities.Add) > 0 {
		for _, cap := range c.SecurityContext.Capabilities.Add {
			if strings.EqualFold(string(cap), "NET_ADMIN") {
				ok, err := namespaceAllowsNetAdmin(ns, cs)
				if err != nil {
					errs = append(errs, field.Invalid(fp.Child("securityContext", "capabilities", "add"), "NET_ADMIN", fmt.Sprintf("ns check error: %v", err)))
				} else if !ok {
					errs = append(errs, field.Forbidden(fp.Child("securityContext", "capabilities", "add"), "NET_ADMIN requires namespace label allow-netadmin=true"))
				}
			}
		}
	}

	return errs
}

func namespaceAllowsNetAdmin(ns string, cs *kubernetes.Clientset) (bool, error) {
	nso, err := cs.CoreV1().Namespaces().Get(context.Background(), ns, metav1.GetOptions{})
	if err != nil {
		return false, err
	}
	return nso.Labels["allow-netadmin"] == "true", nil
}

var cidrRe = regexp.MustCompile(`"ips"\s*:\s*\[\s*"([^"]+)"`)

func validateNetworks(nets string, fp *field.Path) field.ErrorList {
	var errs field.ErrorList
	_, cidrNet, err := net.ParseCIDR(dataPlaneCIDR)
	if err != nil {
		return field.ErrorList{field.Invalid(fp, dataPlaneCIDR, "bad DATA_CIDR")}
	}
	matches := cidrRe.FindAllStringSubmatch(nets, -1)
	for _, m := range matches {
		ipCidr := m[1]
		ip, _, err := net.ParseCIDR(ipCidr)
		if err != nil {
			errs = append(errs, field.Invalid(fp, ipCidr, "not a valid CIDR"))
			continue
		}
		if !cidrNet.Contains(ip) {
			errs = append(errs, field.Forbidden(fp, fmt.Sprintf("IP %s not in %s", ip.String(), cidrNet.String())))
		}
	}
	return errs
}

func isAllowedRegistry(image string) bool {
	reg := image
	if idx := strings.Index(image, "/"); idx > 0 {
		reg = image[:idx]
	}
	for _, allowed := range allowedRegistries {
		a := strings.TrimSpace(allowed)
		if a == "" {
			continue
		}
		if strings.EqualFold(a, reg) || strings.HasPrefix(reg, a) {
			return true
		}
	}
	return false
}
