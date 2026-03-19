FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

ENV POWERSHELL_TELEMETRY_OPTOUT=1
WORKDIR /app

COPY . /app

EXPOSE 8080

CMD ["pwsh", "-NoProfile", "-Command", "$port = if ($env:PORT) { [int]$env:PORT } else { 8080 }; & /app/server.ps1 -Port $port"]
