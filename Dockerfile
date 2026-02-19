# --- STAGE 1: DOWNLOAD ---
FROM ruby:4.0.1-slim-bookworm AS download

WORKDIR /fonts

RUN apt-get update && apt-get install -y --no-install-recommends \
    fontforge \
    wget \
    ca-certificates \
    && wget https://github.com/satbyy/go-noto-universal/releases/download/v7.0/GoNotoKurrent-Regular.ttf \
    && wget https://github.com/satbyy/go-noto-universal/releases/download/v7.0/GoNotoKurrent-Bold.ttf \
    && wget https://github.com/impallari/DancingScript/raw/master/fonts/DancingScript-Regular.otf \
    && wget https://cdn.jsdelivr.net/gh/notofonts/notofonts.github.io/fonts/NotoSansSymbols2/hinted/ttf/NotoSansSymbols2-Regular.ttf \
    && wget https://github.com/Maxattax97/gnu-freefont/raw/master/ttf/FreeSans.ttf \
    && wget https://github.com/impallari/DancingScript/raw/master/OFL.txt \
    && wget -O /model.onnx "https://github.com/docusealco/fields-detection/releases/download/2.0.0/model_704_int8.onnx" \
    && wget -O pdfium-linux.tgz "https://github.com/docusealco/pdfium-binaries/releases/latest/download/pdfium-linux-$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/').tgz" \
    && mkdir -p /pdfium-linux \
    && tar -xzf pdfium-linux.tgz -C /pdfium-linux \
    && rm -rf /var/lib/apt/lists/*

RUN fontforge -lang=py -c 'font1 = fontforge.open("FreeSans.ttf"); font2 = fontforge.open("NotoSansSymbols2-Regular.ttf"); font1.mergeFonts(font2); font1.generate("FreeSans.ttf")'

# --- STAGE 2: WEBPACK (ASSETS) ---
FROM ruby:4.0.1-slim-bookworm AS webpack

ENV RAILS_ENV=production
ENV NODE_ENV=production
ENV RUBY_YJIT_ENABLE=0

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    nodejs \
    npm \
    git \
    build-essential \
    && npm install -g yarn \
    && gem install shakapacker \
    && rm -rf /var/lib/apt/lists/*

COPY ./package.json ./yarn.lock ./
RUN yarn install --network-timeout 1000000

COPY ./bin/shakapacker ./bin/shakapacker
COPY ./config/webpack ./config/webpack
COPY ./config/shakapacker.yml ./config/shakapacker.yml
COPY ./postcss.config.js ./postcss.config.js
COPY ./tailwind.config.js ./tailwind.config.js
COPY ./tailwind.form.config.js ./tailwind.form.config.js
COPY ./tailwind.application.config.js ./tailwind.application.config.js
COPY ./app/javascript ./app/javascript
COPY ./app/views ./app/views

RUN echo "gem 'shakapacker'" > Gemfile && ./bin/shakapacker

# --- STAGE 3: FINAL APP ---
FROM ruby:4.0.1-slim-bookworm AS app

ENV RAILS_ENV=production
ENV BUNDLE_WITHOUT="development:test"
ENV RUBY_YJIT_ENABLE=0
ENV OPENSSL_CONF=/etc/openssl_legacy.cnf

WORKDIR /app

# Installation des dépendances (Noms corrigés pour Debian)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    libpq-dev \
    libvips-dev \
    libyaml-dev \
    redis-server \
    libheif-dev \
    libvips42 \
    fonts-freefont-ttf \
    && mkdir -p /fonts \
    && rm -rf /var/lib/apt/lists/*

# Création de l'utilisateur (Syntaxe Debian)
RUN groupadd -g 2000 docuseal && \
    useradd -u 2000 -g docuseal -m -s /bin/sh docuseal

RUN echo $'.include = /etc/ssl/openssl.cnf\n\
\n\
[provider_sect]\n\
default = default_sect\n\
legacy = legacy_sect\n\
\n\
[default_sect]\n\
activate = 1\n\
\n\
[legacy_sect]\n\
activate = 1' >> /etc/openssl_legacy.cnf

COPY --chown=docuseal:docuseal ./Gemfile ./Gemfile.lock ./

# Installation des Gems
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && bundle install \
    && apt-get purge -y --auto-remove build-essential git \
    && rm -rf /var/lib/apt/lists/* ~/.bundle /usr/local/bundle/cache

COPY --chown=docuseal:docuseal ./bin ./bin
COPY --chown=docuseal:docuseal ./app ./app
COPY --chown=docuseal:docuseal ./config ./config
COPY --chown=docuseal:docuseal ./db/migrate ./db/migrate
COPY --chown=docuseal:docuseal ./log ./log
COPY --chown=docuseal:docuseal ./lib ./lib
COPY --chown=docuseal:docuseal ./public ./public
COPY --chown=docuseal:docuseal ./tmp ./tmp
COPY --chown=docuseal:docuseal LICENSE README.md Rakefile config.ru .version ./
COPY --chown=docuseal:docuseal .version ./public/version

# Récupération des fichiers des stages précédents
COPY --chown=docuseal:docuseal --from=download /fonts/GoNotoKurrent-Regular.ttf /fonts/GoNotoKurrent-Bold.ttf /fonts/DancingScript-Regular.otf /fonts/OFL.txt /fonts/
COPY --from=download /fonts/FreeSans.ttf /usr/share/fonts/truetype/freefont/
COPY --from=download /pdfium-linux/lib/libpdfium.so /usr/lib/libpdfium.so
COPY --from=download /pdfium-linux/licenses/pdfium.txt /usr/lib/libpdfium-LICENSE.txt
COPY --chown=docuseal:docuseal --from=download /model.onnx /app/tmp/model.onnx
COPY --chown=docuseal:docuseal --from=webpack /app/public/packs ./public/packs

RUN ln -s /fonts /app/public/fonts && \
    bundle exec bootsnap precompile -j 1 --gemfile && \
    chown -R docuseal:docuseal /app/tmp/cache

WORKDIR /data/docuseal
ENV HOME=/home/docuseal
ENV WORKDIR=/data/docuseal

USER docuseal

EXPOSE 3000
CMD ["/app/bin/bundle", "exec", "puma", "-C", "/app/config/puma.rb", "--dir", "/app"]
