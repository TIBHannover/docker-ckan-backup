FROM postgres:12-alpine

COPY create restore /usr/local/bin/

RUN chmod +x /usr/local/bin/* && \
    ln -s /usr/local/bin/create /usr/local/bin/backup && \
    mkdir /backup

ENV CKAN_BACKUP_VERSION=0.0.3

ENTRYPOINT [ "" ]