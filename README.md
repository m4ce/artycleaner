# Artifactory housekeeper

A small application utility which allows to clean up Artifactory repos based on some search criteria.

Pull requests are very welcome. I only implemented what I needed.

## Install

You can pull a pre-built image available at Docker Hub as follows:

```shell
$ docker pull m4ce/artycleaner
```

## Usage

If you choose to run the process in a Docker container, I suggest you start from here:

```shell
$ docker run -it m4ce/artycleaner --help
```

The utility reads a configuration file that defaults to `/app/artycleaner.yaml`. If you wish to pass your own configuration file without building your own image, have a look at [bind mount volumes](https://docs.docker.com/engine/reference/commandline/run/#mount-volume--v---read-only).

```yaml
---
api:
  # Artifactory REST endpoint
  endpoint: 'https://example.org/artifactory'
  # HTTP basic authentication
  #username: ''
  #password: ''
  # API key based authentication (preferred)
  api_key: ''
  ssl_verify: false
defaults:
  # Consider artifacts that have not been used in the last 60 days
  purge_ttl: "60d"
  # Minimum number of tags to keep per image (only supported on Docker repos)
  keep_tags: 60
  # Patterns (regex supported) to include for purge. On Docker repos, this will match the name of the image. On all others, the path will be used instead.
  include_pattern: []
  # Patterns (regex supported) to exclude from purge. On Docker repos, this will match the name of the image. On all others, the path will be used instead.
  exclude_pattern: []
  # Tags (regex supported) to include for purge (only supported on Docker repos)
  include_tags: []
  # Tags (regex supported) to exclude from purge (only supported on Docker repos)
  exclude_tags:
    - "latest"
repos:
  "docker-local":
    purge_ttl: "30d"
    keep_tags: 30
    exclude_tags:
      - 'stable'
```

All the defaults options can be overidden at the repository level. However, options like `include_pattern`, `exclude_pattern`, `include_tags` & `exclude_tags` will be (uniquely) merged.

## Contact
Matteo Cerutti - matteo.cerutti@hotmail.co.uk
