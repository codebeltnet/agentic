FROM dhi.io/alpine-base:{AlpineVersion} AS certificates

RUN test -s /etc/ssl/certs/ca-certificates.crt

FROM dhi.io/aspnetcore:{DotNetMajor}-alpine{AlpineVersion}
WORKDIR /app
ENV HOME=/home/app

COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chown=65532:65532 artifacts/publish/ .

EXPOSE 8080

ENTRYPOINT ["dotnet", "{ProjectName}.dll"]
