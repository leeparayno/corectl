PROG = corectl
DAEMON = corectld
ORGANIZATION = github.com/TheNewNormal
REPOSITORY = $(ORGANIZATION)/$(PROG)

GOARCH ?= $(shell go env GOARCH)
GOOS ?= $(shell go env GOOS)
CGO_ENABLED = 1
GO15VENDOREXPERIMENT = 1

BUILD_DIR ?= $(shell pwd)/bin
GOPATH := $(shell echo $(PWD) | \
        sed -e "s,src/$(REPOSITORY).*,,"):$(shell mkdir -p Godeps && \
		godep go env | grep GOPATH | sed -e 's,",,g' -e "s,.*=,,")
GODEP = GOPATH=$(GOPATH) GO15VENDOREXPERIMENT=$(GO15VENDOREXPERIMENT) \
    GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) godep
GOBUILD = $(GODEP) go build

VERSION := $(shell git describe --abbrev=6 --dirty=+untagged --always --tags)
BUILDDATE = $(shell /bin/date "+%FT%T%Z")

HYPERKIT_GIT = "https://github.com/docker/hyperkit.git"
HYPERKIT_COMMIT = c42f126

SKYDNS_GIT = "https://github.com/skynetservices/skydns.git"
SKYDNS_COMMIT = 00ade30

ETCD_GIT = "https://github.com/coreos/etcd.git"
# v3.0.1
ETCD_COMMIT = a4a52cb

MKDIR = /bin/mkdir -p
CP = /bin/cp
MV = /bin/mv
RM = /bin/rm -rf
DATE = /bin/date
SED = /usr/bin/sed
TOUCH = /usr/bin/touch
GIT = /usr/bin/git

ifeq ($(DEBUG),true)
    GO_GCFLAGS := $(GO_GCFLAGS) -N -l
	GOBUILD = $(GOBUILD) -race
else
    GO_LDFLAGS := $(GO_LDFLAGS) -w -s
endif

ETCD_REPO = github.com/coreos/etcd
ETCD_GO_LDFLAGS := $(GO_LDFLAGS) -X \
	$(ETCD_REPO)/cmd/vendor/$(ETCD_REPO)/version.GitSHA=$(ETCD_COMMIT).corectld-$(VERSION)

GO_LDFLAGS := $(GO_LDFLAGS) \
	-X $(REPOSITORY)/release.Version=$(VERSION) \
	-X $(REPOSITORY)/release.BuildDate=$(BUILDDATE)

default: documentation

documentation: documentation/man documentation/markdown
	-$(GIT) status

all: clean Godeps hyperkit corectld.nameserver foo/src/github.com/coreos/etcd documentation

cmd: cmd/client cmd/server

cmd/client: force
	$(RM) $(BUILD_DIR)/$(PROG)
	$(MKDIR) $(BUILD_DIR)
	cd $@; $(GOBUILD) -o $(BUILD_DIR)/$(PROG) \
		-gcflags "$(GO_GCFLAGS)" -ldflags "$(GO_LDFLAGS)"
	@$(TOUCH) $@

cmd/server: force
	$(RM) $(BUILD_DIR)/$(DAEMON)
	$(MKDIR) $(BUILD_DIR)
	cd $@; $(GOBUILD) -o $(BUILD_DIR)/$(DAEMON) \
		-gcflags "$(GO_GCFLAGS)" -ldflags "$(GO_LDFLAGS)"
	@$(TOUCH) $@

components/common/assets: force
	cd $@; \
		$(RM) assets_vfsdata.go ; \
		$(GODEP) go run assets_generator.go -tags=dev

clean: components/common/assets
	$(RM) $(BUILD_DIR)/*
	$(RM) hyperkit
	$(RM) foo
	$(RM) documentation/
	$(RM) $(PROG)-$(VERSION).tar.gz

tarball: $(PROG)-$(VERSION).tar.gz

$(PROG)-$(VERSION).tar.gz: documentation \
		hyperkit corectld.nameserver foo/src/github.com/coreos/etcd
	cd bin; tar cvzf ../$@ *

Godeps: force
	$(RM) $@
	$(RM) vendor/
	# XXX unlike as with etcd we cheat with skydns as upstream doesn't do any
	# kind of vendoring
	$(RM) corectld.nameserver
	$(GIT) clone $(SKYDNS_GIT) corectld.nameserver
	cd corectld.nameserver; $(GIT) checkout $(SKYDNS_COMMIT)
	# XXX godep won't save this as a build dep run a runtime one so we cheat...
	$(SED) -i.bak \
		-e s"|github.com/helm/helm/log|github.com/shurcooL/vfsgen|" \
		-e "s|import (|import ( \"github.com/shurcooL/httpfs/vfsutil\"|" \
			components/common/assets/assets.go
	$(GODEP) save ./...
	# ... and then un-cheat
	$(CP) components/common/assets/assets.go.bak \
		components/common/assets/assets.go
	$(RM) components/common/assets/assets.go.bak
	$(RM) corectld.nameserver
	-$(GIT) status

corectld.nameserver: force
	$(RM) corectld.nameserver
	$(GIT) clone $(SKYDNS_GIT) corectld.nameserver
	cd $@; $(GIT) checkout $(SKYDNS_COMMIT) ;\
		$(GOBUILD) -o $(BUILD_DIR)/$@

foo/src/$(ETCD_REPO): force
	$(RM) $@
	$(MKDIR) $@/..
	cd $@/..; $(GIT) clone $(ETCD_GIT)
	cd $@; $(GIT) checkout $(ETCD_COMMIT);
	cd $@/cmd; \
		GOPATH=$(shell echo $(PWD)/../../../..):$(shell echo \
		$(PWD)/Godeps/_workspace) GO15VENDOREXPERIMENT=$(GO15VENDOREXPERIMENT) \
			GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=$(CGO_ENABLED) \
			godep go build -o $(BUILD_DIR)/$(DAEMON).store \
			-ldflags "$(ETCD_GO_LDFLAGS)"

hyperkit: force
	# - ocaml stack
	#   - 1st run
	# 	  - brew install opam
	# 	  - opam init -y
	# 	  - opam pin add qcow-format
	#					"git://github.com/mirage/ocaml-qcow#master" -y
	# 	  - opam install --yes uri qcow-format ocamlfind
	#   - maintenance
	#     - opam update && opam upgrade -y
	# 	  - opam pin add qcow-format
	#					"git://github.com/mirage/ocaml-qcow#master" -y
	# 	  - opam install --yes uri qcow-format ocamlfind
	#   - build
	#     - make clean
	#     - eval `opam config env` && make all
	$(MKDIR) $(BUILD_DIR)
	$(RM) $@
	$(GIT) clone $(HYPERKIT_GIT)
	cd $@; \
		$(GIT) checkout $(HYPERKIT_COMMIT); \
		$(MAKE) clean; \
		$(shell opam config env) $(MAKE) all
	$(CP) $@/build/com.docker.hyperkit $(BUILD_DIR)/corectld.runner

documentation/man: cmd force
	$(MKDIR) $@
	$(BUILD_DIR)/$(PROG) utils genManPages
	$(BUILD_DIR)/$(DAEMON) utils genManPages
	for p in $$(ls $@/*.1); do \
		$(SED) -i.bak "s/$$($(DATE) '+%h %Y')//" "$$p" ;\
		$(SED) -i.bak "/spf13\/cobra$$/d" "$$p" ;\
		$(RM) "$$p.bak" ;\
	done

documentation/markdown: cmd force
	$(MKDIR) $@
	$(BUILD_DIR)/$(PROG) utils genMarkdownDocs
	$(BUILD_DIR)/$(DAEMON) utils genMarkdownDocs
	for p in $$(ls $@/*.md); do \
		$(SED) -i.bak "/spf13\/cobra/d" "$$p" ;\
		$(RM) "$$p.bak" ;\
	done

.PHONY: clean all docs force assets cmd
