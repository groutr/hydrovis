FROM mambaorg/micromamba AS micromamba

# Create conda environment for hydrovis
RUN --mount=type=bind,source=conda-linux-64.lock,target=/tmp/conda.lock \
    micromamba install -y --file /tmp/conda.lock && \
    micromamba clean -afy

# Clean out unnecessary files to reduce image size
RUN find /opt/conda -regex '^.*\(__pycache__\|\.py[co]\)$' -delete && \
    find /opt/conda -follow -type f -name '*.a' -delete
RUN rm -rf /opt/conda/man /opt/conda/share/man /opt/conda/share/doc && \
    rm -rf /opt/conda/include && \
    rm -rf /opt/conda/share/bash-completion && \
    rm -rf /opt/conda/share/info && \
    rm -rf /opt/conda/share/examples && \
    rm -rf /opt/conda/conda-meta


FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal AS alinux

ENV MAMBA_ROOT_PREFIX="/opt/conda"
ENV MAMBA_EXE="/bin/micromamba"
# Prevent Python from writing bytecode files
ENV PYTHONDONTWRITEBYTECODE=1
# Prevent python from buffering stdout
ENV PYTHONUNBUFFERED=1
COPY --from=micromamba --chown=root "$MAMBA_EXE" "$MAMBA_EXE"
COPY --from=micromamba --chown=root /opt/conda /opt/conda
COPY --from=micromamba --chown=root /usr/local/bin/_*.sh /usr/local/bin/

WORKDIR /home/code

# Copy function code
COPY products/ ./products/
COPY lambda_function.py \
    viz_classes.py \
    viz_lambda_shared_funcs.py \
    ./

SHELL ["/usr/local/bin/_dockerfile_shell.sh"]

ENTRYPOINT [ "/usr/local/bin/_entrypoint.sh" ]
CMD [ \
    "python", "-m", "awslambdaric", "lambda_function.lambda_handler" \
]
