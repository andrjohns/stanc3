@Library('StanUtils')
import org.stan.Utils

def utils = new org.stan.Utils()

pipeline {
    agent none
    stages {
        stage('Kill previous builds') {
            when {
                not { branch 'develop' }
                not { branch 'master' }
            }
            steps {
                script {
                    utils.killOldBuilds()
                    sh "rm -rf _build"
                }
            }
        }
        stage("Build & Test") {
            agent {
                dockerfile {
                    filename 'docker/dev-ubuntu/Dockerfile'
                    args '-u root --privileged' // TODO: set up a proper user in Dockerfile
                }
            }
            steps {
                sh """
                      rm -rf _build
                      eval \$(opam env)
                      dune build @install
                   """
                sh """
                      eval \$(opam env)
                      dune runtest
                   """
            }
        }
        stage("Build & Test static linux binary") {
            agent {
                dockerfile {
                    filename 'docker/static/Dockerfile'
                }
            }
            steps {
                sh """
                      rm -rf _build
                      eval \$(opam env)
                      dune build @install --profile static
                   """
                sh """
                      eval \$(opam env)
                      dune runtest --profile static
                   """
            }
        }
    }
    post {
        always {
            script {utils.mailBuildResults()}
        }
    }

}
