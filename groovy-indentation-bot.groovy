#!/usr/bin/groovy

import groovy.json.JsonSlurperClassic
import groovy.json.JsonOutput

pipeline {

  agent {
    label "my-agent"
  }

  parameters {
    string(name: 'PULL_REQUEST_FROM_HASH', defaultValue: '')
    string(name: 'PULL_REQUEST_TO_REPO_PROJECT_KEY', defaultValue: '')
    string(name: 'PULL_REQUEST_TO_REPO_SLUG', defaultValue: '')
    string(name: 'PULL_REQUEST_ID', defaultValue:'')
    string(name: 'PULL_REQUEST_COMMENT_ACTION', defaultValue: '')
    string(name: 'PULL_REQUEST_COMMENT_TEXT', defaultValue:'')
    string(name: 'PULL_REQUEST_FROM_HTTP_CLONE_URL', defaultValue:'')
    string(name: 'PULL_REQUEST_FROM_BRANCH', defaultValue:'')
  }

  environment {
    mode = "IGNORE"
    status = "START"
  }

  stages {

    stage("Validate trigger") {
      steps {
        script {
          // Bot triggered on comment (ADDED/DELETED/EDITED/REPLIED)
          if ("${PULL_REQUEST_COMMENT_ACTION}" != "") {
            // We only care about new added comments
            if ("${PULL_REQUEST_COMMENT_ACTION}" == "ADDED") {
              // Trigger only when matching the keywords
              if ("${PULL_REQUEST_COMMENT_TEXT}" == "indent me please") {
                mode = "INDENT"
              }
            }
          } else { // Bot triggered by a commit in the pull request
            mode = "VALIDATE"
          }
        }
      }
    }

    stage("Notifying start") {
      when {
        expression { getBotMode() != Mode.IGNORE }
      }
      steps {
          notifyPullRequest()
      }
    }

    stage("Running") {
      when {
        expression { getBotMode() != Mode.IGNORE }
      }
      steps {
        script {
          dir("/tmp/${BUILD_NUMBER}") {
            def ret = sh(returnStatus: true, script: """
                git clone ${PULL_REQUEST_FROM_HTTP_CLONE_URL}
                cd ${PULL_REQUEST_TO_REPO_SLUG}
                git config --local user.email "team-bitbucket-bot@company.com"
                git config --local user.name "team-bitbucket-bot"
                git checkout ${PULL_REQUEST_FROM_BRANCH}
                git reset --hard ${PULL_REQUEST_FROM_HASH}
                docker run --rm --user \$(id -u):\$(id -g) --volume \$(pwd):/data aallrd/intellij-format -r -m \\*.groovy .
                git status
                git diff --quiet
              """)
            setBotStatus(ret as Integer)
            if (getBotMode() == Mode.INDENT && getBotStatus() == Status.HAS_DIFF) {
              withCredentials([usernamePassword(credentialsId: 'team-bitbucket-bot', passwordVariable: 'GIT_PASSWORD', usernameVariable: 'GIT_USERNAME')]) {
                ret = sh(returnStatus: true, script: """
                  cd ${PULL_REQUEST_TO_REPO_SLUG}
                  git status
                  git commit -am \"Code automatically indented by the groovy-indentation-bot\"
                  __repo="\$(echo "${PULL_REQUEST_FROM_HTTP_CLONE_URL}" | awk -F'@' '{ print \$2 }')"
                  git push --repo https://${GIT_USERNAME}:${GIT_PASSWORD}@\${__repo}
                """)
                if(ret as Integer == 0) {
                  env.commit = sh(returnStdout: true, script: "cd ${PULL_REQUEST_TO_REPO_SLUG} && git rev-parse --short HEAD").trim()
                } else {
                  status = "FAILURE"
                }
              }
            }
            deleteDir()
          }
        }
      }
    }

    stage("Notifying result") {
      when {
        expression { getBotMode() != Mode.IGNORE }
      }
      steps {
          notifyPullRequest(true)
      }
    }
  }
}

enum Status {
  START, HAS_DIFF, NO_DIFF, FAILURE
}

Status getBotStatus() {
  if(status == "START") { return Status.START }
  else if(status == "HAS_DIFF") { return Status.HAS_DIFF }
  else if(status == "NO_DIFF") { return Status.NO_DIFF }
  else if(status == "FAILURE") { return Status.FAILURE }
  else { error("Unknown status: ${status}") }
}

def setBotStatus(Integer code) {
  if(code == 0) { status = "NO_DIFF" }
  else if(code == 1) { status = "HAS_DIFF" }
  else { error("Unknown code: ${code}") }
}

enum Mode {
  IGNORE, VALIDATE, INDENT
}

Mode getBotMode() {
  if(mode == "IGNORE") { return Mode.IGNORE }
  else if(mode == "VALIDATE") { return Mode.VALIDATE }
  else if(mode == "INDENT") { return Mode.INDENT }
  else { error("Unknown mode: ${mode}") }
}

def notifyPullRequest(Boolean update = false) {
  Mode mode = getBotMode()
  Status status = getBotStatus()
  String bitbucket_hostname = "bitbucket.company.com"
  String bitbucket_api_url = "http://${bitbucket_hostname}/rest/api/1.0"
  String pull_request_url = "${bitbucket_api_url}/projects/${PULL_REQUEST_TO_REPO_PROJECT_KEY}/repos/${PULL_REQUEST_TO_REPO_SLUG}/pull-requests/${PULL_REQUEST_ID}"
  String pull_request_comments_url = "${pull_request_url}/comments"
  if(update) {
    pull_request_comments_url = "${pull_request_comments_url}/${env.commentId}"
  }
  def response = httpRequest(
    acceptType: 'APPLICATION_JSON',
    authentication: 'team-bitbucket-bot',
    consoleLogResponseBody: true,
    contentType: 'APPLICATION_JSON',
    httpMode: update ? "PUT" : "POST",
    ignoreSslErrors: true,
    requestBody: getComment(mode, status),
    responseHandle: 'NONE',
    url: "${pull_request_comments_url}"
  )
  if(response.getStatus() == 400) { error("Failed to notify the pull request: ${pull_request_url}") }
  if(!update) {
    env.commentId = new JsonSlurperClassic().parseText(response.getContent()).id
  }
}

private String getComment(Mode mode, Status status) {
  String running_marker = "**[BUILD RUNNING]**"
  String success_marker = "**[✓ BUILD SUCCESSFUL]**"
  String failure_marker = "**[✕ BUILD FAILED]**"
  String ref = "([#${BUILD_NUMBER}](${BUILD_URL}))"
  String marker = ""
  String desc = ""
  String note = ""
  def node = [:]

  if (mode == Mode.VALIDATE) {
    if (status == Status.START) {
      marker = running_marker
      desc = "Checking your groovy code indentation..."
    } else if(status == Status.NO_DIFF) {
      marker = success_marker
      desc = "The indentation check was **successful**."
    } else if(status == Status.HAS_DIFF) {
      marker = failure_marker
      desc = "The indentation check **failed**."
      note = "Please use the _docker-intellij-format_ project to format your groovy code: " +
        "[docker-intellij-format](https://github.com/aallrd/docker-intellij-format)\n" +
        "You can ask the bot to indent your code by commenting _indent me please_ on this pull request."
    }
    else { error("Unknown status") }
  } else if (mode == Mode.INDENT) {
    if (status == Status.START) {
      marker = running_marker
      desc = "Indenting your groovy code..."
    } else if(status == Status.NO_DIFF) {
      marker = success_marker
      desc = "Your groovy code is already properly indented."
    } else if(status == Status.HAS_DIFF) {
      marker = success_marker
      desc = "Your groovy code was **successfully** indented."
      note = "Commit: [${env.commit}](https://bitbucket.company.com/projects/${PULL_REQUEST_TO_REPO_PROJECT_KEY}/repos/" +
        "${PULL_REQUEST_TO_REPO_SLUG}/pull-requests/${PULL_REQUEST_ID}/commits/${env.commit})"
    } else if(status == Status.FAILURE) {
      marker = failure_marker
      desc = "Something wrong happened :(."
    }
    else { error("Unknown status") }
  }

  String comment = java.lang.String.format("%s %s %s\n%s", marker, desc, ref, note)
  node.put("version", 0)
  node.put("text", comment)
  return JsonOutput.toJson(node)
}

