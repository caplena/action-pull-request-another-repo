FROM alpine:3.17

RUN apk update && \
    apk upgrade && \
    apk add git && \
    apk add go && \
    apk add make && \
    apk add make && \
    apk add rsync && \
    apk add jq && \
    git clone --depth 1 --branch v2.26.1 https://github.com/cli/cli.git gh-cli && \
    cd gh-cli && \
    make && \
    mv ./bin/gh /usr/local/bin/

ADD entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
