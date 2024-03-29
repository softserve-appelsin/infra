{{ range $app := .Values.apps }}
# PR: {{ $app.name | upper }}
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: appelsin-{{ $app.name }}-pr
spec:
  template:
    serviceAccountName: appelsin-workflow-sa
  dependencies:
    - name: pr
      eventSourceName: github
      eventName: all-events
      filters:
        data:
          # https://docs.github.com/en/developers/webhooks-and-events/webhook-events-and-payloads
          - path: headers.X-Github-Event
            type: string
            value:
              - pull_request
          - path: body.action
            type: string
            value:
              - opened
              - edited
              - reopened
              - synchronize
          - path: body.pull_request.state
            type: string
            value:
              - open
          - path: body.pull_request.base.ref
            type: string
            value:
              - main
              - stage
          - path: body.repository.name
            type: string
            value:
              - {{ $app.name }}
  triggers:
    - template:
        name: github-workflow-trigger
        k8s:
          operation: create
          source:
            resource:
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: github-
              spec:
                entrypoint: main
                onExit: exit-handler
                volumes:
                - name: docker-config
                  secret:
                    secretName: docker-config
                    items:
                    - key: .dockerconfigjson
                      path: config.json
                - name: push-key
                  secret:
                    secretName: deployment-key
                    items:
                      - key: ssh-privatekey
                        path: infra
                arguments:
                  parameters:
                    - name: repo-owner  # 0
                    - name: repo-name   # 1
                    - name: repo-url    # 2
                    - name: repo-ssh    # 3
                    - name: pr-number   # 4
                    - name: sha         # 5
                    - name: short-sha   # 6
                templates:
                  - name: main
                    inputs:
                      parameters:
                        - name: repo-name
                        - name: repo-owner
                        - name: repo-url
                        - name: repo-ssh
                        - name: pr-number
                        - name: sha
                        - name: short-sha
                    dag:
                      tasks:
                      - name: status-pending
                        templateRef:
                          name: github-status
                          template: main
                        arguments:
                          parameters:
                          - name: name 
                            value: argo-events
                          - name: description 
                            value: Running tests
                          - name: repo
                            value: '{{`{{inputs.parameters.repo-owner}}`}}/{{`{{inputs.parameters.repo-name}}`}}'
                          - name: sha
                            value: '{{`{{inputs.parameters.sha}}`}}'
                          - name: status
                            value: pending

                      - name: build-image
                        depends: status-pending
                        templateRef:
                          name: kaniko
                          template: main
                        arguments:
                          parameters:
                          - name: repo
                            value: "{{`{{inputs.parameters.repo-url}}`}}"
                          - name: revision
                            value: '{{`{{inputs.parameters.sha}}`}}'
                          - name: image
                            value: 2xnone/appelsin-{{ $app.name }}
                          - name: dockerfile
                            value: {{ $app.dockerfile }}
                          - name: tag
                            value: '{{`{{inputs.parameters.short-sha}}`}}'

                      - name: run-tests
                        depends: build-image
                        template: run-tests
                        arguments:
                          parameters:
                          - name: short-sha
                            value: '{{`{{inputs.parameters.short-sha}}`}}'

                  - name: run-tests
                    inputs:
                      parameters:
                        - name: short-sha
                    container:
                      name: run-tests
                      image: 2xnone/appelsin-{{ $app.name }}:{{`{{inputs.parameters.short-sha}}`}}
                      command: ["/bin/sh", "-c"]
                      args: [{{ $app.tests.command | quote }}]
                      env:
                        - name: SECRET_KEY_PROJECT
                          value: "CI-example"

                  - name: exit-handler
                    inputs:
                      parameters:
                        - name: repo-name
                        - name: repo-owner
                        - name: pr-number
                        - name: sha
                    dag:
                      tasks:
                      # SUCCESS
                      - name: github-status-success
                        when: "'{{`{{workflow.status}}`}}' == 'Succeeded'"
                        templateRef:
                          name: github-status
                          template: main
                        arguments:
                          parameters:
                          - name: name 
                            value: argo-events
                          - name: description 
                            value: Tests completed
                          - name: repo
                            value: '{{`{{inputs.parameters.repo-owner}}`}}/{{`{{inputs.parameters.repo-name}}`}}'
                          - name: sha
                            value: '{{`{{inputs.parameters.sha}}`}}'
                          - name: status
                            value: success
                      - name: telegram-status-success
                        when: "'{{`{{workflow.status}}`}}' == 'Succeeded'"
                        templateRef:
                          name: telegram-send
                          template: main
                        arguments:
                          parameters:
                          - name: message
                            value: '✅ {{`{{inputs.parameters.repo-owner}}`}}/{{`{{inputs.parameters.repo-name}}`}} PR #{{`{{inputs.parameters.pr-number}}`}} - success'

                    # FAILURE
                      - name: github-status-failure
                        when: "'{{`{{workflow.status}}`}}' != 'Succeeded'"
                        templateRef:
                          name: github-status
                          template: main
                        arguments:
                          parameters:
                          - name: name
                            value: argo-events
                          - name: description
                            value: Tests failed
                          - name: repo
                            value: '{{`{{inputs.parameters.repo-owner}}`}}/{{`{{inputs.parameters.repo-name}}`}}'
                          - name: sha
                            value: '{{`{{inputs.parameters.sha}}`}}'
                          - name: status
                            value: failure
                      - name: telegram-status-failure
                        when: "'{{`{{workflow.status}}`}}' != 'Succeeded'"
                        templateRef:
                          name: telegram-send
                          template: main
                        arguments:
                          parameters:
                          - name: message
                            value: '❌ {{`{{inputs.parameters.repo-owner}}`}}/{{`{{inputs.parameters.repo-name}}`}} PR #{{`{{inputs.parameters.pr-number}}`}} - failed'
          parameters:
            # Workflow name  <owner>-<repo>-pr-<pr-no>-<short-sha>
            - src:
                dependencyName: pr
                dataTemplate: "{{`{{ .Input.body.repository.owner.login }}`}}-{{`{{ .Input.body.repository.name }}`}}-pr-{{`{{ .Input.body.pull_request.number }}`}}-{{`{{ .Input.body.pull_request.head.sha | substr 0 7 }}`}}"
              dest: metadata.name
              operation: append
            # repo owner
            - src:
                dependencyName: pr
                dataKey: body.repository.owner.login
              dest: spec.arguments.parameters.0.value
            # repo name
            - src:
                dependencyName: pr
                dataKey: body.repository.name
              dest: spec.arguments.parameters.1.value
            # repo url
            - src:
                dependencyName: pr
                dataTemplate: "https://github.com/{{`{{ .Input.body.repository.owner.login }}`}}/{{`{{ .Input.body.repository.name }}`}}"
              dest: spec.arguments.parameters.2.value
            # repo ssh
            - src:
                dependencyName: pr
                dataTemplate: "git@github.com:{{`{{ .Input.body.repository.owner.login }}`}}/{{`{{ .Input.body.repository.name }}`}}"
              dest: spec.arguments.parameters.3.value
            # pr number
            - src:
                dependencyName: pr
                dataKey: body.pull_request.number
              dest: spec.arguments.parameters.4.value
            # sha
            - src:
                dependencyName: pr
                # dataTemplate: "{{`{{ .Input.body.pull_request.head.sha | substr 0 7 }}`}}"
                dataTemplate: "{{`{{ .Input.body.pull_request.head.sha }}`}}"
              dest: spec.arguments.parameters.5.value
            # short-sha
            - src:
                dependencyName: pr
                dataTemplate: "{{`{{ .Input.body.after | substr 0 7 }}`}}"
              dest: spec.arguments.parameters.6.value

      retryStrategy:
        steps: 3
---
{{ end }}
