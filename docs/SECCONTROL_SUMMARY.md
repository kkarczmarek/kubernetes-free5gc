# Kontrola dostępu w Kubernetes

## Teza
Praktyczne wdrożenie i egzekwowanie zaawansowanej kontroli dostępu: RBAC (least privilege), Pod Security (PSA), NetworkPolicy, reguły admission (Kyverno), oraz bezpieczny workflow Git.

## Co jest w repo
- `policies/` — PSA, NetworkPolicy, Kyverno (NET_ADMIN tylko w labelowanych NS, verify-images).
- `rbac/` — role i powiązania (least privilege dla operacji).
- `docs/` — te notatki i checklisty.
- Manifesty aplikacji pozostają bez zmian (sekrety poza repo).

## Główne punkty dowodu
1. Domyślnie *zamknięty* klaster (PSA restricted + NetworkPolicy default-deny).
2. Wyjątki (NET_ADMIN/sysctl) tylko w jawnie oznaczonych NS — polityka Kyverno.
3. Minimalne role operacyjne — patch/update tylko na wybranych zasobach.
4. Gotowość pod GitOps i wymaganie podpisów obrazów (verifyImages).

## Następne kroki
- Włączyć weryfikację podpisów obrazów (Cosign public key).
- Spiąć RBAC z OIDC/SSO grupami.
- AuditPolicy + Falco/Tetragon dla runtime.
