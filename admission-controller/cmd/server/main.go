package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const (
	requiredNS       = "5g-core"
	labelPartOfKey   = "app.kubernetes.io/part-of"
	labelProjectKey  = "project"
	labelPartOfValue = "free5gc"
	labelProjectVal  = "free5gc"
)

type admitFunc func(ar admissionv1.AdmissionReview) *admissionv1.AdmissionResponse

func main() {
	cert := getEnv("TLS_CERT", "/tls/tls.crt")
	key := getEnv("TLS_KEY", "/tls/tls.key")

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	http.HandleFunc("/mutate", serve(admitMutate))
	http.HandleFunc("/validate", serve(admitValidate))

	server := &http.Server{Addr: ":8443"}
	// Load TLS
	if _, err := os.Stat(cert); err == nil {
		cfg := &tls.Config{}
		pair, err := tls.LoadX509KeyPair(cert, key)
		if err != nil {
			log.Fatalf("load key pair: %v", err)
		}
		cfg.Certificates = []tls.Certificate{pair}
		server.TLSConfig = cfg
		log.Printf("listening on https://0.0.0.0:8443")
		log.Fatal(server.ListenAndServeTLS("", ""))
	} else {
		log.Printf("TLS cert not found, serving HTTP (dev only) on :8080")
		server.Addr = ":8080"
		log.Fatal(server.ListenAndServe())
	}
}

func serve(f admitFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var review admissionv1.AdmissionReview
		if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
			writeReview(w, toError(err))
			return
		}
		resp := f(review)
		out := admissionv1.AdmissionReview{TypeMeta: review.TypeMeta, Response: resp}
		out.Response.UID = review.Request.UID
		writeReview(w, &out)
	}
}

func toError(err error) *admissionv1.AdmissionResponse {
    return &admissionv1.AdmissionResponse{
        Allowed: false,
        Result:  &metav1.Status{Message: err.Error()},
    }
}

func admitMutate(ar admissionv1.AdmissionReview) *admissionv1.AdmissionResponse {
	req := ar.Request
	if req == nil {
		return allow("no request")
	}

	// Only mutate namespaced objects in required namespace
	if req.Namespace != requiredNS {
		return allow("outside target namespace")
	}

	switch req.Kind.Kind {
	case "Deployment":
		var obj appsv1.Deployment
		if err := json.Unmarshal(req.Object.Raw, &obj); err != nil {
			return toError(err)
		}
		patchOps := ensureLabels(obj.ObjectMeta)
		return patchResponse(patchOps)
	case "StatefulSet", "DaemonSet":
		return allow("no-op for now")
	case "Service", "ConfigMap", "Secret":
		// Extract only metadata for labels
		var meta metav1.ObjectMeta
		type metaWrapper struct {
			Metadata metav1.ObjectMeta `json:"metadata"`
		}
		var w metaWrapper
		if err := json.Unmarshal(req.Object.Raw, &w); err == nil {
			meta = w.Metadata
		}
		patchOps := ensureLabels(meta)
		return patchResponse(patchOps)
	default:
		return allow("kind not targeted")
	}
}

func admitValidate(ar admissionv1.AdmissionReview) *admissionv1.AdmissionResponse {
	req := ar.Request
	if req == nil {
		return allow("no request")
	}
	if req.Namespace != requiredNS {
		return deny(fmt.Sprintf("resources must be created in namespace %s", requiredNS))
	}

	switch req.Kind.Kind {
	case "Deployment":
		var obj appsv1.Deployment
		if err := json.Unmarshal(req.Object.Raw, &obj); err != nil {
			return toError(err)
		}
		// Labels present?
		if !hasRequiredLabels(obj.ObjectMeta.Labels) {
			return deny("missing required labels: app.kubernetes.io/part-of=free5gc and project=free5gc")
		}
		// Basic security & resources checks
		for _, c := range obj.Spec.Template.Spec.Containers {
			if c.Resources.Requests == nil || c.Resources.Limits == nil {
				return deny("all containers must define resources.requests and resources.limits")
			}
			if c.SecurityContext != nil && c.SecurityContext.Privileged != nil && *c.SecurityContext.Privileged {
				return deny("privileged containers are not allowed")
			}
			_ = corev1.Container{} // to ensure corev1 import remains
		}
		return allow("ok")
	case "Service", "ConfigMap", "Secret":
		// Extract labels
		type metaWrapper struct {
			Metadata metav1.ObjectMeta `json:"metadata"`
		}
		var w metaWrapper
		if err := json.Unmarshal(req.Object.Raw, &w); err != nil {
			return toError(err)
		}
		if !hasRequiredLabels(w.Metadata.Labels) {
			return deny("missing required labels")
		}
		return allow("ok")
	default:
		return allow("kind not validated")
	}
}

// Helpers

type patchOp struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func ensureLabels(meta metav1.ObjectMeta) []patchOp {
	ops := []patchOp{}
	labels := meta.Labels
	if labels == nil {
		// add labels map
		ops = append(ops, patchOp{Op: "add", Path: "/metadata/labels", Value: map[string]string{}})
	}
	if !hasRequiredLabels(labels) {
		// add keys individually (JSON Pointer escape for '/')
		ops = append(ops, patchOp{Op: "add", Path: "/metadata/labels/app.kubernetes.io~1part-of", Value: labelPartOfValue})
		ops = append(ops, patchOp{Op: "add", Path: "/metadata/labels/project", Value: labelProjectVal})
	}
	return ops
}

func hasRequiredLabels(lbls map[string]string) bool {
	if lbls == nil {
		return false
	}
	if lbls[labelPartOfKey] != labelPartOfValue {
		return false
	}
	if lbls[labelProjectKey] != labelProjectVal {
		return false
	}
	return true
}

func patchResponse(ops []patchOp) *admissionv1.AdmissionResponse {
	if len(ops) == 0 {
		return allow("no changes")
	}
	b, _ := json.Marshal(ops)
	t := admissionv1.PatchTypeJSONPatch
	return &admissionv1.AdmissionResponse{Allowed: true, Patch: b, PatchType: &t}
}

func allow(msg string) *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{Allowed: true, Result: &metav1.Status{Message: msg}}
}

func deny(msg string) *admissionv1.AdmissionResponse {
	return &admissionv1.AdmissionResponse{Allowed: false, Result: &metav1.Status{Reason: metav1.StatusReason(msg)}}
}

func writeReview(w http.ResponseWriter, ar interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(ar)
}

func getEnv(k, def string) string {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	return v
}
