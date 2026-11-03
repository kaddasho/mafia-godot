# Mafia game server: headless Godot running this folder.
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.7.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/* \
 && wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip \
 && unzip -q Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip \
 && mv Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
 && rm Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip

WORKDIR /app
COPY . .
RUN rm -rf tests .gdignore

ENV PORT=10000
EXPOSE 10000
CMD ["godot", "--headless", "--path", "/app"]
