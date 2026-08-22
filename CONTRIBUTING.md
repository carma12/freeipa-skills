# Contributing to FreeIPA Skill Marketplace

If you designed a usefull skill to aid FreeIPA development,
you can share with other developers by sharing trough this
marketplace.

## How to Contribute

Once you have your skill or skill set in a publicly avaiable repository,
with the proper structure (see below), you have to:

1. Fork this repository
2. Add your module to `lola.yml`
4. Send us a pull request

To add your module to `lola.yml`, just add an entry containing:

```yaml
- name: "your-module-name"
  description: "Brief, clear description of what it does"
  version: "1.0.0"
  repository: "https://github.com/username/your-module"
  tags:
    - "relevant-category"
    - "another-keyword"
```

## Questions and Issues

For any issue or question on using the marketplace, open an issue.

For issues with the actual skills, open an issue against the skill repository.
