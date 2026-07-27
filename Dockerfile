FROM golang:1.26.5-alpine AS gateway-build

WORKDIR /src
COPY go.mod go.sum ./
COPY cmd/whip-gateway ./cmd/whip-gateway
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/harbor-whip-gateway ./cmd/whip-gateway

FROM alexxit/go2rtc:1.9.14

COPY --from=gateway-build /out/harbor-whip-gateway /usr/local/bin/
COPY scripts/run-container.sh /usr/local/bin/harbor-homekit-container
RUN chmod 0755 /usr/local/bin/harbor-whip-gateway \
    /usr/local/bin/harbor-homekit-container \
    && addgroup -g 1000 harbor \
    && adduser -D -H -u 1000 -G harbor harbor \
    && mkdir -p /harbor /config \
    && chown -R harbor:harbor /harbor /config

USER harbor
CMD ["/usr/local/bin/harbor-homekit-container"]
