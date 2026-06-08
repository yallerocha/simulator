# MongoDB server portável (amd64 + ppc64le/Power9).
# A imagem oficial `mongo` não tem build ppc64le; o conda-forge tem MongoDB 6.0
# para ppc64le, então construímos a partir do miniforge (multi-arch).
FROM condaforge/miniforge3:latest

# Instala o servidor MongoDB do conda-forge (tem build ppc64le).
RUN mamba install -y -c conda-forge mongodb=6.0.12 && mamba clean -afy

# Diretório de dados (compatível com a imagem oficial: volume em /data/db).
RUN mkdir -p /data/db

EXPOSE 27017

# bind_ip_all para aceitar conexões de fora do container (broker/monitor).
CMD ["mongod", "--bind_ip_all", "--dbpath", "/data/db"]
