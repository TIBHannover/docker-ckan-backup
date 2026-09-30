FROM postgres:16-alpine

COPY create restore /usr/local/bin/

# Install GNU tar to support append operation
# Make scripts executable
# Prepare the backup folder
RUN apk add --no-cache tar && \
    chmod +x /usr/local/bin/* && \
    ln -s /usr/local/bin/create /usr/local/bin/backup && \
    mkdir /backup

ENV CKAN_BACKUP_VERSION=2.1.4
ENTRYPOINT [ "" ]