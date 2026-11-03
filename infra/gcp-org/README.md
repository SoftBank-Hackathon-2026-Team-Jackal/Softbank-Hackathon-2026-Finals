# gcp-org

GCP 조직(`soulee.dev`) 아래의 폴더, 프로젝트, 조직 정책, 예산, 팀원 IAM을 관리하는 스택입니다. 구조와 결정 배경은 [클라우드 계정 구조](../../notes/cloud-structure.md)와 [작업 기록](../../notes/2026-11-03-cloud-setup-log.md) 7절에 있습니다.

## 스택 두 개

| 스택 | 실행 계정 | 관리하는 것 |
|---|---|---|
| `bootstrap/` | `admin@soulee.dev` | 조직 관리자의 `orgpolicy.policyAdmin`, 도메인 제한 정책 해제, `alus20x@gmail.com`의 조직 역할 |
| `.` (이 디렉터리) | `alus20x@gmail.com` | 폴더 `prod`와 `sandbox`, 프로젝트 `sbh26-prod`와 `sbh26-sandbox`, API, 리전 제한 정책, 예산, 팀원 Editor |

조직 관리자 계정은 부트스트랩과 비상시에만 씁니다. state는 두 스택 모두 AWS 관리 계정의 org state 버킷(`gcp-org/` 키)에 있으므로, 실행할 때 AWS `mgmt` 프로필도 로그인되어 있어야 합니다.

## 실행

ADC를 바꾸지 않도록 단기 액세스 토큰을 씁니다.

```bash
aws sso login --sso-session sbh26

# bootstrap/
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=admin@soulee.dev)

# 이 디렉터리
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=alus20x@gmail.com)

terraform plan
terraform apply
```

## 콘솔과 외부에서 설정한 값

| 위치 | 설정 | 값 |
|---|---|---|
| Cloud Identity Free | 조직 | `soulee.dev`, 관리자 `admin@soulee.dev` |
| Cloudflare DNS (`soulee.dev`) | 도메인 인증 | `google-site-verification` TXT 레코드 |
| Cloudflare Email Routing | `admin@soulee.dev` 전달 | `alus20x@gmail.com`으로 전달 (설정했다면) |
| Cloud Billing | 결제 계정 | `alus20x@gmail.com`이 소유. ID는 `team.auto.tfvars`에 둠 |

## 새 조직에 기본으로 적용된 정책

`iam.allowedPolicyMemberDomains`만 `bootstrap/`에서 풀었고, 나머지(서비스 계정 키 생성과 업로드 금지, 기본 서비스 계정 자동 권한 금지, 버킷 단위 권한 등)는 그대로 둡니다. 목록은 작업 기록 7.4절에 있습니다.

## 팀원

팀원은 각자의 Google 계정으로 로그인합니다. `team.auto.tfvars`의 `team_members`에 `user:<이메일>` 형식으로 추가하고 apply합니다. 이 파일은 이메일이 들어 있어 커밋하지 않습니다.

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project sbh26-prod
```
