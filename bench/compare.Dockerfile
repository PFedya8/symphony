# syntax=docker/dockerfile:1
FROM golang:1.25.4-bookworm AS go-build
WORKDIR /src/go-manual
COPY go-manual/ ./
RUN --mount=type=secret,id=proxy_ca,required=true \
    SSL_CERT_FILE=/run/secrets/proxy_ca go build -o /go-manual .

FROM hexpm/elixir:1.19.4-erlang-28.3-debian-bookworm-20260202-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ENV ERL_FLAGS="+S 2:2"
WORKDIR /app/elixir
COPY elixir/mix.exs elixir/mix.lock ./
RUN --mount=type=secret,id=proxy_ca,required=true \
    HEX_CACERTS_PATH=/run/secrets/proxy_ca SSL_CERT_FILE=/run/secrets/proxy_ca \
    sh -c 'mix local.hex --force && mix local.rebar --force && mix deps.get'
COPY elixir/config/ ./config/
COPY elixir/lib/ ./lib/
COPY elixir/priv/ ./priv/
COPY elixir/demo.exs elixir/demo-workflow.md ./
RUN --mount=type=secret,id=proxy_ca,required=true \
    HEX_CACERTS_PATH=/run/secrets/proxy_ca SSL_CERT_FILE=/run/secrets/proxy_ca mix compile
COPY --from=go-build /go-manual /app/bench/go-manual
COPY bench/compare.py bench/elixir-launch.exs /app/bench/
COPY cli/symphonyctl /app/cli/symphonyctl
ENTRYPOINT ["python3", "/app/bench/compare.py"]
