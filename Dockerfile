FROM alpine:3.6

# install jq, python3
RUN apk --update add \
  curl \
  jq \
  python3

# install aws cli
RUN pip3 install awscli --upgrade

# install kubectl
# for now, force to 1.7.5 because of bug https://github.com/kubernetes/kubernetes/issues/53309
# eventually may just use "latest" via the below
ENV KUBECTL_VERSION v1.7.5
RUN curl -o /usr/local/bin/kubectl -LO https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
  && chmod +x /usr/local/bin/kubectl
#RUN curl -o /usr/local/bin/kubectl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl \
#  && chmod +x /usr/local/bin/kubectl


COPY run-backup.sh /
ENTRYPOINT /run-backup.sh
