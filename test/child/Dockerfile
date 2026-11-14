# The test child: built on the app-jupyter image under test, exactly as the
# README's "Build your own Jupyter image on this one" says, with the base passed
# in (test/run.sh sets it).
ARG BASE
FROM ${BASE}
COPY . /tmp/osp/
RUN /app/osp/install.sh /tmp/osp
RUN /app/osp/finish-build.sh
