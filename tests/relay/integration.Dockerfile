FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
LABEL com.bitrix-relay.integration-test="true"
RUN apk add --no-cache bash curl ca-certificates openssh-server openssh-client-default \
      openssl shadow python3 iproute2 util-linux coreutils \
    && addgroup -S relay \
    && adduser -S -D -H -G relay -s /sbin/nologin relay \
    && mkdir -p /run/sshd
ENTRYPOINT ["python3", "-B", "/repo/tests/relay/integration.py", "/repo/install.sh"]
