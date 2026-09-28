FROM mcr.microsoft.com/powershell:7.4-debian-12

WORKDIR /app

COPY . .

ENV PORT=10000

EXPOSE 10000

CMD ["pwsh", "-NoProfile", "-File", "./Run-Cvi.ps1", "-Cloud", "-NoBrowser", "-LocalJudge"]