#!/usr/bin/env bash
set -euo pipefail

mkdir -p admission-controller/cmd/server k8s tests tools

cat > admission-controller/go.mod <<'EOF'
module github.com/kkarczmarek/kubernetes-free5gc/admission-controller

go 1.22

require (
    k8s.io/api v0.30.2
    k8s.io/apimachinery v0.30.2
    k8s.io/client-go v0.30.2
)
EOF

cat > admission-controller/Dockerfile <<'EOF'
FROM golang:1.22 as build
WORKDIR /src
COPY go.mod .
RUN go mod download
COPY cmd/server ./cmd/server
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/admission-webhook ./cmd/server

FROM gcr.io/distroless/static:nonroot
WORKDIR /
USER nonroot:nonroot
COPY --from=build /out/admission-webhook /admission-webhook
EXPOSE 8443
ENTRYPOINT ["/admission-webhook"]
EOF

cat > admission-controller/cmd/server/main.go <<'EOF'
[ZA DŁUGIE NA OKIENKO—> Otwórz następną wiadomość ode mnie; wkleisz cały plik main.go]
EOF

cat > k8s/20-certmanager-issuer.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: admission-system
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: admission-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webhook-cert
  namespace: admission-system
spec:
  secretName: webhook-tls
  issuerRef:
    name: selfsigned-issuer
  commonName: webhook-svc.admission-system.svc
  dnsNames:
    - webhook-svc.admission-system.svc
    - webhook-svc.admission-system.svc.cluster.local
EOF

cat > k8s/30-webhook-deploy-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: webhook-svc
  namespace: admission-system
spec:
  selector:
    app: admission-webhook
  ports:
    - port: 443
      targetPort: 8443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admission-webhook
  namespace: admission-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: admission-webhook
  template:
    metadata:
      labels:
        app: admission-webhook
    spec:
      containers:
        - name: server
          image: IMAGE_PLACEHOLDER
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8443
          env:
            - name: DEFAULT_CPU_REQUEST
              value: "50m"
            - name: DEFAULT_MEM_REQUEST
              value: "128Mi"
            - name: DEFAULT_CPU_LIMIT
              value: "500m"
            - name: DEFAULT_MEM_LIMIT
              value: "512Mi"
            - name: FREE5GC_NAMESPACE
              value: "free5gc"
            - name: DATA_CIDR
              value: "10.100.50.0/24"
            - name: ALLOWED_REGISTRIES
              value: "ghcr.io,public.ecr.aws,docker.io"
            - name: DENY_LATEST_TAG
              value: "true"
          volumeMounts:
            - name: tls
              mountPath: /tls
              readOnly: true
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
      volumes:
        - name: tls
          secret:
            secretName: webhook-tls
EOF

cat > k8s/40-mutatingwebhook.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: admission-mutating-webhook
  annotations:
    cert-manager.io/inject-ca-from: admission-system/webhook-cert
webhooks:
  - name: mutate.free5gc.local
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Ignore
    timeoutSeconds: 10
    clientConfig:
      service:
        name: webhook-svc
        namespace: admission-system
        path: /mutate
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["free5gc"]
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE","UPDATE"]
        resources: ["pods"]
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE","UPDATE"]
        resources: ["deployments","statefulsets","daemonsets"]
EOF

cat > k8s/50-validatingwebhook.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: admission-validating-webhook
  annotations:
    cert-manager.io/inject-ca-from: admission-system/webhook-cert
webhooks:
  - name: validate.free5gc.local
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    timeoutSeconds: 15
    clientConfig:
      service:
        name: webhook-svc
        namespace: admission-system
        path: /validate
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: ["free5gc"]
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE","UPDATE"]
        resources: ["pods"]
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE","UPDATE"]
        resources: ["deployments","statefulsets","daemonsets"]
EOF

cat > tests/01-deploy-missing-labels.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t-missing-labels
  namespace: free5gc
spec:
  replicas: 1
  selector: { matchLabels: { app: t-missing-labels } }
  template:
    metadata:
      labels: { app: t-missing-labels }
    spec:
      containers:
        - name: c
          image: public.ecr.aws/bitnami/nginx:1.25.5
          resources: {}
EOF

cat > tests/02-deploy-no-resources.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t-no-resources
  namespace: free5gc
  labels: { app.kubernetes.io/part-of: free5gc }
spec:
  replicas: 1
  selector: { matchLabels: { app: t-no-resources } }
  template:
    metadata:
      labels: { app: t-no-resources, app.kubernetes.io/part-of: free5gc }
    spec:
      containers:
        - name: c
          image: public.ecr.aws/bitnami/nginx:1.25.5
EOF

cat > tests/03-deploy-bad-image.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: t-bad-image
  namespace: free5gc
  labels: { app.kubernetes.io/part-of: free5gc }
spec:
  replicas: 1
  selector: { matchLabels: { app: t-bad-image } }
  template:
    metadata:
      labels: { app: t-bad-image, app.kubernetes.io/part-of: free5gc }
    spec:
      containers:
        - name: c
          image: docker.io/library/nginx:latest
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits:   { cpu: 100m, memory: 256Mi }
EOF

cat > tests/04-deploy-hostnetwork.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: t-hostnetwork
  namespace: free5gc
  labels: { app.kubernetes.io/part-of: free5gc }
spec:
  hostNetwork: true
  containers:
    - name: c
      image: public.ecr.aws/bitnami/nginx:1.25.5
      resources:
        requests: { cpu: 50m, memory: 128Mi }
        limits:   { cpu: 100m, memory: 256Mi }
EOF

echo "OK - struktura i pliki gotowe. Teraz wklej poprawny main.go (patrz następna wiadomość) i uruchom: bash tools/apply-webhook-update.sh ponownie aby nadpisać placeholder."
