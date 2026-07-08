# CI/CD Pipeline Blueprint

Projeden bağımsız, kopyala-yapıştır bir CI/CD boru hattı şablonu. Herhangi bir .NET projesine kısa sürede uyarlanır: kendinden barındırmalı GitHub Actions çalıştırıcısı üzerinde otomatik derleme/test, onaya bağlı üretim dağıtımı, sağlık kontrolü ve otomatik geri alma.

A project-agnostic, copy-paste CI/CD pipeline template. Adapts to any .NET project quickly: automatic build/test on a self-hosted GitHub Actions runner, approval-gated production deployment, health checks and automatic rollback.

---

## Dokümantasyon / Documentation

| Dil / Language | Belge / Document |
|---|---|
| Türkçe | [`docs/ci-cd-blueprint.tr.md`](./docs/ci-cd-blueprint.tr.md) |
| English | [`docs/ci-cd-blueprint.en.md`](./docs/ci-cd-blueprint.en.md) |

## Tek yapılandırma kaynağı / Single source of configuration

Sistemin tamamı tek bir `SERVICES` bloğuyla yapılandırılır. Her satır bir servis:
The entire system is configured with a single `SERVICES` block. One service per line:

```
name|csproj|deploy_dir|service_name|health_url
```

```
web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5200
```

## Hızlı başlangıç / Quick start

1. `templates/.github` ve `templates/scripts` klasörlerini kendi deponuzun köküne kopyalayın. / Copy `templates/.github` and `templates/scripts` to your repository root.
2. `ci.yml`, `deploy.yml`, `rollback.yml` içindeki `SERVICES` / `services` bloğunu doldurun. / Fill in the `SERVICES` / `services` blocks.
3. Tüm workflow'larda `runs-on` etiketini ayarlayın. / Set the `runs-on` label in all workflows.
4. Host'ta bir kez: `sudo SERVICES="..." bash scripts/setup-host.sh`. / Once on the host.
5. GitHub'da `production` ortamı + required reviewers ekleyin. / Add a `production` environment with required reviewers.

Ayrıntılı adımlar için dokümana bakın. / See the docs for detailed steps.

## Dosya yapısı / File structure

```
cicd-blueprint/
├── README.md
├── docs/
│   ├── ci-cd-blueprint.tr.md
│   └── ci-cd-blueprint.en.md
└── templates/
    ├── .github/
    │   ├── actions/build-test/action.yml
    │   └── workflows/{ci,reusable-dotnet-ci,deploy,rollback}.yml
    └── scripts/{pipeline,verify-health,setup-host}.sh
```

## İş akışları / Workflows

| Workflow | Tetikleme / Trigger | Ne yapar / What it does |
|---|---|---|
| `ci.yml` | push / PR (main) | Derleme + test, (push'ta) artifact / Build + test, artifact on push |
| `deploy.yml` | elle / manual | Onaylı üretim dağıtımı + health + otomatik rollback / Approval-gated deploy |
| `rollback.yml` | elle / manual | Önceki klasör veya belirli commit / Previous folder or specific commit |

> Somut, doldurulmuş bir örnek için `../cicd-eshop` (eShopOnWeb) referans alınabilir. eShop yalnızca örnektir; bu şablonu kullanmak için gerekli değildir.
> For a concrete, filled-in example see `../cicd-eshop` (eShopOnWeb). eShop is only an example; it is not required to use this template.
