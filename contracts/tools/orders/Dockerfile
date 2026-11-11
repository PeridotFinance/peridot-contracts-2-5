FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl python3 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_linux_amd64.tar.gz -o /tmp/foundry.tar.gz \
    && echo 'cf7e688ed0c4c48adffca788b496076e31060b67ac5afe1e43dbb5499c20c88b  /tmp/foundry.tar.gz' | sha256sum -c - \
    && tar -xzf /tmp/foundry.tar.gz -C /usr/local/bin cast && rm /tmp/foundry.tar.gz
WORKDIR /app
COPY contracts/tools/orders/orders_keeper.py /app/keeper/orders_keeper.py
COPY contracts/tools/orders/worker.py /app/keeper/worker.py
RUN useradd --uid 10001 --create-home keeper
USER keeper
CMD ["python3", "keeper/worker.py"]
