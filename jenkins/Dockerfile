FROM golang:1.27 AS go

FROM jenkins/jenkins:lts-jdk21

USER root

COPY --from=go /usr/local/go /usr/local/go
COPY --from=docker:cli /usr/local/bin/docker /usr/local/bin/docker

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOCACHE=/var/jenkins_home/.cache/go-build