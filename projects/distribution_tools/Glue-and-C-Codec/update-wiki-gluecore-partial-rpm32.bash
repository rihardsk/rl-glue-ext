#!/bin/bash
#Update the RPM Wiki Template
VERSION=`./install_root/usr/local/bin/rl_glue --pv`
FILENAME=rl-glue-${VERSION}-2_i386.rpm
python filesubstitution.py $VERSION $FILENAME wiki/templates/RLGlueCore.wiki.rpm32.template wiki/current/RLGlueCore.wiki.rpm32

