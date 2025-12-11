#!/bin/bash

# ==============================================================================
# OSSM 3.2 + Tempo + Bookinfo GitOps Generator
# ==============================================================================
# This script generates a full GitOps folder structure for OpenShift Service Mesh 3.2
# configured with Gateway API and a full observability stack.
# ==============================================================================

# Configuration
REPO_URL="https://github.com/maudis73/ossm.git"  # <--- CHANGE THIS LATER IN ARGOCD
OCP_DOMAIN="apps.example.com"                         # <--- CHANGE THIS IF KNOWN (used for Route hostname placeholder)

echo "🚀 Starting GitOps Repo Generation..."

# 1. Create Directory Structure
mkdir -p bootstrap
mkdir -p infra/ossm/base
mkdir -p infra/observability/base
mkdir -p apps/bookinfo/base
mkdir -p apps/bookinfo/gateway

# ==============================================================================
# 1. INFRA: Observability (Tempo + MinIO + Kiali Config)
# ==============================================================================
echo "📦 Generating Observability Config..."

cat <<EOF > infra/observability/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - minio.yaml
  - tempo.yaml
  - kiali-config.yaml
EOF

cat <<EOF > infra/observability/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tracing-system
EOF

# MinIO (Fake S3)
cat <<EOF > infra/observability/base/minio.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: tracing-system
spec:
  selector:
    matchLabels:
      app: minio
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: "minio"
        - name: MINIO_ROOT_PASSWORD
          value: "minio123"
        ports:
        - containerPort: 9000
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: tracing-system
spec:
  ports:
  - port: 9000
    protocol: TCP
    targetPort: 9000
  selector:
    app: minio
---
apiVersion: v1
kind: Secret
metadata:
  name: tempostack-dev-minio
  namespace: tracing-system
stringData:
  bucket: tempo
  endpoint: http://minio.tracing-system.svc.cluster.local:9000
  access_key_id: minio
  access_key_secret: minio123
type: Opaque
EOF

# TempoStack
cat <<EOF > infra/observability/base/tempo.yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: tempo
  namespace: tracing-system
spec:
  storage:
    secret:
      name: tempostack-dev-minio
      type: s3
  storageSize: 1Gi
  resources:
    total:
      limits:
        memory: 2Gi
        cpu: 2000m
  template:
    queryFrontend:
      jaegerQuery:
        enabled: true
EOF

# Kiali Configuration (CR)
# Note: We assume Kiali Operator is installed, this configures the instance.
cat <<EOF > infra/observability/base/kiali-config.yaml
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali
  namespace: istio-system
spec:
  auth:
    strategy: anonymous # For Lab ease
  deployment:
    accessible_namespaces: ["**"]
  external_services:
    tracing:
      enabled: true
      use_grpc: true
      in_cluster_url: "http://tempo-query-frontend.tracing-system.svc.cluster.local:16685"
      url: "" 
EOF

# ==============================================================================
# 2. INFRA: OpenShift Service Mesh 3.2 (Sail)
# ==============================================================================
echo "🕸️  Generating Service Mesh 3.2 Config..."

cat <<EOF > infra/ossm/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - istio.yaml
  - telemetry.yaml
EOF

cat <<EOF > infra/ossm/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
EOF

# The main Istio CR (Sail Operator)
cat <<EOF > infra/ossm/base/istio.yaml
apiVersion: sailoperator.io/v1alpha1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.20.0 # Adjust based on your Sail operator version
  namespace: istio-system
  values:
    meshConfig:
      enableTracing: true
      extensionProviders:
      - name: tempo
        opentelemetry:
          port: 4317
          service: tempo-distributor.tracing-system.svc.cluster.local
      defaultConfig:
        tracing:
          sampling: 100.0
EOF

# Global Telemetry Rule
cat <<EOF > infra/ossm/base/telemetry.yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-tracing
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: tempo
EOF

# ==============================================================================
# 3. APPS: Bookinfo (Application + Gateway API)
# ==============================================================================
echo "📚 Downloading Bookinfo Source & Generating Gateway API..."

# Download raw Bookinfo YAMLs to ensure independence
curl -s https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml -o apps/bookinfo/base/bookinfo-deployment.yaml

cat <<EOF > apps/bookinfo/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - bookinfo-deployment.yaml
EOF

cat <<EOF > apps/bookinfo/base/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/rev: default  # Enables Sidecar Injection for OSSM 3.x
EOF

# Gateway API Configuration (The Entrypoint)
cat <<EOF > apps/bookinfo/gateway/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway.yaml
  - httproute.yaml
  - openshift-route.yaml
EOF

# The Gateway API Resource
cat <<EOF > apps/bookinfo/gateway/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

# The HTTPRoute (Routing rules)
cat <<EOF > apps/bookinfo/gateway/httproute.yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: bookinfo
spec:
  parentRefs:
  - name: bookinfo-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /productpage
    - path:
        type: PathPrefix
        value: /static
    - path:
        type: PathPrefix
        value: /login
    - path:
        type: PathPrefix
        value: /logout
    - path:
        type: PathPrefix
        value: /api/v1/products
    backendRefs:
    - name: productpage
      port: 9080
EOF

# The OpenShift Route (Exposes the Gateway to the outside world)
# NOTE: OSSM 3 / Sail creates a Service for the Gateway named "<gateway-name>-istio" usually.
cat <<EOF > apps/bookinfo/gateway/openshift-route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: bookinfo-gateway
  namespace: bookinfo
spec:
  port:
    targetPort: 80
  to:
    kind: Service
    name: bookinfo-gateway-istio # Sail usually appends -istio
    weight: 100
  wildcardPolicy: None
EOF

# ==============================================================================
# 4. BOOTSTRAP: ArgoCD App of Apps
# ==============================================================================
echo "🚀 Generating ArgoCD Bootstrap..."

cat <<EOF > bootstrap/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap-cluster
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: '${REPO_URL}'
    targetRevision: HEAD
    path: bootstrap
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-observability
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: '${REPO_URL}'
    targetRevision: HEAD
    path: infra/observability/base
  destination:
    server: https://kubernetes.default.svc
    namespace: tracing-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-ossm
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: '${REPO_URL}'
    targetRevision: HEAD
    path: infra/ossm/base
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-bookinfo
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: '${REPO_URL}'
    targetRevision: HEAD
    path: apps/bookinfo/base
  destination:
    server: https://kubernetes.default.svc
    namespace: bookinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-bookinfo-gateway
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: '${REPO_URL}'
    targetRevision: HEAD
    path: apps/bookinfo/gateway
  destination:
    server: https://kubernetes.default.svc
    namespace: bookinfo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo "✅ Done! Your GitOps folder structure is ready."
echo "👉 Next Step: 'git add .', 'git commit', and 'git push' to your repo."
echo "👉 Then apply 'bootstrap/app-of-apps.yaml' to your cluster manually once."
