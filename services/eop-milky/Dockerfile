FROM ghcr.io/laplace-live/eop@sha256:19626145390f1734e4d474d6ff4de8f5073c39801c557af055979b7df2144f28
USER root
RUN apt-get update && apt-get install -y --no-install-recommends patch util-linux && rm -rf /var/lib/apt/lists/*
COPY prepare.ts /opt/eop-milky/scripts/prepare.ts
COPY patches /opt/eop-milky/patches
COPY compat /opt/eop-milky/compat
COPY upstream-integrity.json /opt/eop-milky/upstream-integrity.json
RUN bun /opt/eop-milky/scripts/prepare.ts /app /app
WORKDIR /app
ENTRYPOINT ["bun", "src/compat/launch.ts"]
CMD ["run", "-c", "config.eop.js"]
