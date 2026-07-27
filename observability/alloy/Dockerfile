# Grafana Alloy collector for the Luke fleet (OBS-3). Render builds this image and runs it; the
# config is baked in, all targets/creds come from env vars (set on the Render service).
FROM grafana/alloy:latest

COPY config.alloy /etc/alloy/config.alloy

# Alloy's UI/health on :12345 (Render health-checks it). --disable-reporting opts out of usage stats.
ENTRYPOINT ["/bin/alloy"]
CMD ["run", "--server.http.listen-addr=0.0.0.0:12345", "--disable-reporting", "/etc/alloy/config.alloy"]
