FROM openbao/openbao:latest
USER root
RUN apk add --no-cache curl
USER 1000:1000
