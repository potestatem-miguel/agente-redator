FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

ENV POWERSHELL_TELEMETRY_OPTOUT=1
WORKDIR /app

COPY . /app

EXPOSE 8080

CMD ["pwsh", "-NoProfile", "-File", "/app/server.ps1", "-Port", "8080"]
