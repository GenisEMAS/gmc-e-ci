#!/bin/bash

set -e

# Run pytest on the tests directory,
# which is assumed to be mounted somewhere in the docker image.

here=$(dirname $0)

testvenv=/tmp/testvenv
/usr/bin/python3 -m venv $testvenv
$testvenv/bin/pip install -r $here/requirements.txt

# Use the Odoo virtualenv for python/odoo commands invoked by tests.
export PATH=/opt/odoo-venv/bin:/usr/local/bin:${PATH}

$testvenv/bin/pytest --color=yes --ignore $here/data $here "$@"
