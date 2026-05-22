{{- define "cyberpulse.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $image := index $root.Values.images $name -}}
{{- printf "%s/%s:%s" $root.Values.images.prefix $image.repository $root.Values.images.tag -}}
{{- end -}}

{{- define "cyberpulse.imagePullSecrets" -}}
{{- if .Values.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.imagePullSecrets }}
  - name: {{ .name | quote }}
{{- end }}
{{- end }}
{{- end -}}
