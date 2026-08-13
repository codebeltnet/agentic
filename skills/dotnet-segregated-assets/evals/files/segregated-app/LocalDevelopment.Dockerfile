FROM dhi.io/aspnetcore:10-alpine3.23-dev

WORKDIR /app

COPY --chown=65532:65532 artifacts/publish/ .

USER 65532

ENTRYPOINT ["dotnet", "Fabrikam.Web.dll"]
