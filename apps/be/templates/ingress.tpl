apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Values.name }}-{{ .Valuses.sysenv }}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    kubernetes.io/tls-acme: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: {{ .Values.ingressClass | default "nginx" }}
  tls:
  - hosts:
    - "{{ .Values.ingress.host }}"
    secretName: "{{ .Values.ingress.host }}"
  rules:
  - host: "{{ .Values.ingress.host }}"
    http:
      paths:
      - pathType: Prefix
        path: {{ .Values.ingress.path | default "/" }}
        backend:
          service:
            name: {{ .Values.name }}
            port:
              number: {{ .Values.ingress.port }}
