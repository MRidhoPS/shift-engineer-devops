pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        booleanParam(
            name: 'PUSH_IMAGE',
            defaultValue: false,
            description: 'Push image ke registry. Jika false, tahap Push hanya disimulasikan.'
        )
        choice(
            name: 'DEPLOY_MODE',
            choices: ['local', 'ssh'],
            description: 'local: agent satu host dengan container (akses Docker socket). ssh: deploy ke host lain via SSH.'
        )
    }

    environment {
        IMAGE_NAME       = 'shift-engineer-devops'
        REGISTRY         = 'registry.example.com/shift-engineer'
        REGISTRY_CRED_ID = 'registry-credentials'
        SSH_CRED_ID      = 'deploy-ssh-key'

        CONTAINER_NAME   = 'shift-engineer-devops'
        DEPLOY_DIR       = '/opt/shift-engineer-devops'
        DEPLOY_HOST      = 'deploy.example.com'
        DEPLOY_USER      = 'deploy'
        HEALTH_URL       = "${params.DEPLOY_MODE == 'ssh' ? 'http://localhost:8080/health' : 'http://host.docker.internal:8080/health'}"
        APP_URL          = "${params.DEPLOY_MODE == 'ssh' ? 'http://localhost:8080' : 'http://host.docker.internal:8080'}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'chmod +x scripts/*.sh'
                script {
                    env.GIT_SHORT = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    env.VERSION   = "v${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                }
                echo "Commit  : ${env.GIT_SHORT}"
                echo "Version : ${env.VERSION}"
            }
        }

        stage('Test') {
            steps {
                sh 'go version'
                sh 'go vet ./...'
                sh 'go test ./... -count=1 -cover'
            }
        }

        stage('Build Image') {
            steps {
                sh '''
                    docker build \
                        --build-arg VERSION="${VERSION}" \
                        --label org.opencontainers.image.revision="${GIT_SHORT}" \
                        --label org.opencontainers.image.version="${VERSION}" \
                        -t "${IMAGE_NAME}:${VERSION}" \
                        -t "${IMAGE_NAME}:latest" \
                        .
                '''
            }
        }

        stage('Push') {
            when { expression { params.PUSH_IMAGE } }
            steps {
                withCredentials([usernamePassword(
                    credentialsId: env.REGISTRY_CRED_ID,
                    usernameVariable: 'REG_USER',
                    passwordVariable: 'REG_PASS'
                )]) {
                    sh '''
                        echo "${REG_PASS}" | docker login "${REGISTRY%%/*}" -u "${REG_USER}" --password-stdin
                        docker tag "${IMAGE_NAME}:${VERSION}" "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
                        docker tag "${IMAGE_NAME}:${VERSION}" "${REGISTRY}/${IMAGE_NAME}:latest"
                        docker push "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
                        docker push "${REGISTRY}/${IMAGE_NAME}:latest"
                        docker logout "${REGISTRY%%/*}"
                    '''
                }
            }
        }

        stage('Push (simulated)') {
            when { expression { !params.PUSH_IMAGE } }
            steps {
                echo "Simulasi push. Registry     : ${env.REGISTRY}"
                echo "Simulasi push. Image        : ${env.REGISTRY}/${env.IMAGE_NAME}:${env.VERSION}"
                echo "Simulasi push. Credential ID: ${env.REGISTRY_CRED_ID} (Username with password)"
            }
        }

        stage('Extract Binary') {
            steps {
                sh '''
                    mkdir -p build
                    docker rm -f "extract-${BUILD_NUMBER}" >/dev/null 2>&1 || true
                    docker create --name "extract-${BUILD_NUMBER}" "${IMAGE_NAME}:${VERSION}" >/dev/null
                    docker cp "extract-${BUILD_NUMBER}:/app/server" build/server
                    docker rm -f "extract-${BUILD_NUMBER}" >/dev/null
                    chmod +x build/server
                    ls -lh build/server
                '''
                archiveArtifacts artifacts: 'build/server', fingerprint: true
            }
        }

        stage('Deploy') {
            steps {
                script {
                    if (params.DEPLOY_MODE == 'ssh') {
                        sshagent(credentials: [env.SSH_CRED_ID]) {
                            sh '''
                                TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"
                                OPTS="-o StrictHostKeyChecking=accept-new"

                                ssh ${OPTS} "${TARGET}" "mkdir -p ${DEPLOY_DIR}/scripts ${DEPLOY_DIR}/build ${DEPLOY_DIR}/runtime ${DEPLOY_DIR}/backups"
                                scp ${OPTS} scripts/hotfix.sh scripts/rollback.sh "${TARGET}:${DEPLOY_DIR}/scripts/"
                                scp ${OPTS} build/server "${TARGET}:${DEPLOY_DIR}/build/server"

                                ssh ${OPTS} "${TARGET}" \
                                    "cd ${DEPLOY_DIR} && chmod +x scripts/*.sh && CONTAINER_NAME=${CONTAINER_NAME} HEALTH_URL=${HEALTH_URL} ./scripts/hotfix.sh build/server"
                            '''
                        }
                    } else {
                        sh '''
                            CONTAINER_BINARY="${DEPLOY_DIR}/runtime/server" \
                            BACKUP_DIR="${DEPLOY_DIR}/backups" \
                            ./scripts/hotfix.sh build/server
                        '''
                    }
                }
            }
        }

        stage('Verify Version') {
            steps {
                script {
                    if (params.DEPLOY_MODE == 'ssh') {
                        sshagent(credentials: [env.SSH_CRED_ID]) {
                            sh '''
                                RESP="$(ssh -o StrictHostKeyChecking=accept-new "${DEPLOY_USER}@${DEPLOY_HOST}" "curl -fsS ${APP_URL}")"
                                echo "${RESP}"
                                echo "${RESP}" | grep -q "version=${VERSION}"
                            '''
                        }
                    } else {
                        sh '''
                            RESP="$(curl -fsS "${APP_URL}")"
                            echo "${RESP}"
                            echo "${RESP}" | grep -q "version=${VERSION}"
                        '''
                    }
                }
            }
        }
    }

    post {
        always {
            sh 'docker rm -f "extract-${BUILD_NUMBER}" >/dev/null 2>&1 || true'
        }
        success {
            echo "Deploy ${env.VERSION} berhasil. Container dan image tidak di-rebuild atau di-recreate."
        }
        failure {
            echo 'Pipeline gagal. Jika gagal setelah Deploy, hotfix.sh sudah melakukan auto-rollback saat health check gagal. Rollback manual: ./scripts/rollback.sh backups/<file>'
        }
    }
}