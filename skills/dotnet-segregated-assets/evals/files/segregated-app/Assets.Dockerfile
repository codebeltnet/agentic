FROM codebeltnet/web-cdn-origin:2.0.0

COPY --chown=65532:65532 ./wwwroot/ /cdnroot/
