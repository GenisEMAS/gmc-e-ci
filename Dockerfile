ARG codename=focal

FROM ubuntu:$codename
ENV LANG=C.UTF-8
USER root

# Basic dependencies
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq --no-install-recommends \
    ca-certificates \
    curl \
    gettext \
    git \
    gnupg \
    lsb-release \
    software-properties-common \
    expect-dev \
    pipx

ENV PIPX_BIN_DIR=/usr/local/bin

# Install wkhtml
RUN case $(lsb_release -c -s) in \
    focal) WKHTML_DEB_URL=https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.5/wkhtmltox_0.12.5-1.focal_amd64.deb ;; \
    jammy) WKHTML_DEB_URL=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb ;; \
    esac \
    && curl -sSL $WKHTML_DEB_URL -o /tmp/wkhtml.deb \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends /tmp/wkhtml.deb  \
    && rm /tmp/wkhtml.deb

# Install nodejs dependencies
RUN case $(lsb_release -c -s) in \
    focal) NODE_SOURCE="deb https://deb.nodesource.com/node_15.x focal main" \
    && curl -sSL https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - ;; \
    jammy) NODE_SOURCE="deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg ;; \
    esac \
    && echo "$NODE_SOURCE" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq nodejs
# less is for odoo<12
RUN npm install -g rtlcss less@3.0.4 less-plugin-clean-css

# Install postgresql client
RUN curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -s -c`-pgdg main" > /etc/apt/sources.list.d/pgclient.list \
    && apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq postgresql-client-12

RUN add-apt-repository -y ppa:deadsnakes/ppa

ARG python_version

# Install build dependencies for python libs commonly used by Odoo and OCA
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -qq --no-install-recommends \
    build-essential \
    python${python_version}-dev \
    python${python_version}-venv \
    # we need python 3 for our helper scripts
    python3 \
    python3-venv \
    # for psycopg
    libpq-dev \
    # for lxml
    libxml2-dev \
    libxslt1-dev \
    libz-dev \
    libxmlsec1-dev \
    # for python-ldap
    libldap2-dev \
    libsasl2-dev \
    # need libjpeg to build older pillow versions
    libjpeg-dev \
    # for pycups
    libcups2-dev \
    # for mysqlclient \
    default-libmysqlclient-dev \
    # some other build tools
    swig \
    libffi-dev \
    pkg-config \
    jq \
    unzip \
    # chrome
    '?and(?name(libatk-bridge.*) | ?name(libatk1.*) | ?name(libdrm2.*) | ?name(libxcomposite1.*) | ?name(libXdamage.*) | ?name(libxfixes3.*) | ?name(libXrandr.*) | ?name(libgbm.*) | ?name(libxkbcommon0.*) | ?name(libpango1.*) | ?name(libcairo2.*) | ?name(libasound2), ?not(?name(.*-dev)))'

# Install Chrome for Odoo browser tests (chrome-for-testing, not a fixed .deb URL).
ARG chrome_milestone=139
RUN curl -fsSL "$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/latest-versions-per-milestone-with-downloads.json | jq -r '.milestones."'"$chrome_milestone"'".downloads.chrome | .[] | select(.platform == "linux64") .url')" -o /tmp/chrome.zip \
    && unzip /tmp/chrome.zip -d /opt \
    && ln -snf /opt/chrome-linux64/chrome /usr/bin/google-chrome \
    && rm /tmp/chrome.zip

# We use manifestoo to check licenses, development status and list addons and dependencies
RUN pipx install --pip-args="--no-cache-dir" "manifestoo>=0.3.1"
# Used in oca_checklog_odoo to check odoo logs for errors and warnings
RUN pipx install --pip-args="--no-cache-dir" checklog-odoo

# Install pyproject-dependencies helper scripts.
ARG build_deps="setuptools-odoo wheel whool"
RUN pipx install --pip-args="--no-cache-dir" pyproject-dependencies
RUN pipx inject --pip-args="--no-cache-dir" pyproject-dependencies $build_deps

# Make a virtualenv for Odoo so we isolate from system python dependencies and
# make sure addons we test declare all their python dependencies properly
ARG setuptools_constraint
RUN python$python_version -m venv /opt/odoo-venv \
    && /opt/odoo-venv/bin/pip install -U "setuptools$setuptools_constraint" "wheel" "pip" \
    && /opt/odoo-venv/bin/pip list
ENV PATH=/opt/odoo-venv/bin:$PATH

ARG odoo_version

# Install Odoo requirements (use ADD for correct layer caching).
# We use requirements from OCB for easier maintenance of older versions.
COPY requirements-ci-constraints.txt /tmp/requirements-ci-constraints.txt
ADD https://raw.githubusercontent.com/OCA/OCB/$odoo_version/requirements.txt /tmp/ocb-requirements.txt
# Install gevent/greenlet from binary wheels (unpinned "gevent" pulls latest
# source and fails to compile with current Cython on Python 3.10).
RUN sed -i -E "/^(gevent|greenlet)==/d" /tmp/ocb-requirements.txt \
    && (pip install --no-cache-dir --only-binary gevent,greenlet \
          -r /tmp/requirements-ci-constraints.txt \
        || pip install --no-cache-dir -r /tmp/requirements-ci-constraints.txt) \
    && pip install --no-cache-dir \
    -r /tmp/ocb-requirements.txt \
    packaging \
    && python -c "import gevent, greenlet, lxml, psycopg2; print('OCB deps OK')"

# Install other test requirements.
# - coverage
# - websocket-client is required for Odoo browser tests
RUN pip install --no-cache-dir \
    coverage \
    websocket-client

# Odoo sources are cloned into ci-deps/ by the CI workflow before docker build.
COPY ci-deps/odoo /opt/odoo
COPY ci-deps/enterprise/ /opt/odoo/addons/

RUN if [ -f /opt/odoo/requirements.txt ]; then \
      sed -i -E "/^(gevent|greenlet)==/d" /opt/odoo/requirements.txt; \
      pip install --no-cache-dir -r /opt/odoo/requirements.txt; \
    fi \
    && pip install --no-cache-dir -e /opt/odoo --config-setting=editable_mode=compat \
    && python -c "import odoo; import odoo.cli" \
    && pip list

# Make an empty odoo.cfg
RUN echo "[options]" > /etc/odoo.cfg
ENV ODOO_RC=/etc/odoo.cfg
ENV OPENERP_SERVER=/etc/odoo.cfg

COPY bin/* /usr/local/bin/

ENV ODOO_VERSION=$odoo_version
ENV PGHOST=postgres
ENV PGUSER=odoo
ENV PGPASSWORD=odoo
ENV PGDATABASE=odoo
# This PEP 503 index uses odoo addons from OCA and redirects the rest to PyPI,
# in effect hiding all non-OCA Odoo addons that are on PyPI.
ENV PIP_INDEX_URL=https://wheelhouse.odoo-community.org/oca-simple-and-pypi
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_PYTHON_VERSION_WARNING=1
# Control addons discovery. INCLUDE and EXCLUDE are comma-separated list of
# addons to include (default: all) and exclude (default: none)
ENV ADDONS_DIR=.
ENV ADDONS_PATH=/opt/odoo/addons
ENV INCLUDE=
ENV EXCLUDE=
ENV OCA_GIT_USER_NAME=DevsEMAS
ENV OCA_GIT_USER_EMAIL=devs_apps@emas.es
ENV OCA_ENABLE_CHECKLOG_ODOO=
