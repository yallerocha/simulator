# Ollama ppc64le — instalado via conda do canal ufcg-ibm
# Usa Miniforge como base (suporta ppc64le nativamente)
FROM condaforge/miniforge3:latest

# Instala o Ollama ppc64le do canal ufcg-ibm + PyYAML para o entrypoint
RUN conda install -y -c ufcg-ibm ollama-ppc64le \
    && conda install -y pyyaml \
    && conda clean -afy

# Copia o script de entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Porta padrão do Ollama
EXPOSE 11434

# Volume para persistir modelos baixados
VOLUME /root/.ollama

# Variáveis de ambiente
ENV OLLAMA_HOST=0.0.0.0:11434

# Entrypoint: lê o config, puxa modelos e cria variantes com Modelfile
ENTRYPOINT ["/entrypoint.sh"]
