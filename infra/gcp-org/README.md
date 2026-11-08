# gcp-org

GCP 조직(`soulee.dev`)의 부트스트랩 설정만 남아 있는 디렉터리입니다.

## 정리 기록 (2026-11-08)

해커톤 본선이 끝난 뒤, 이 디렉터리에 있던 루트 스택을 `terraform destroy`로 삭제하고 코드도 지웠습니다. 삭제한 리소스는 다음과 같습니다.

- 폴더 `prod`, `sandbox`
- 프로젝트 `sbh26-prod`, `sbh26-sandbox`: 삭제 요청 상태이며, 2026-12-08 무렵까지는 `gcloud projects undelete`로 복구할 수 있습니다.
- 리전 제한 조직 정책, 프로젝트별 예산, 팀원의 Editor와 Project IAM Admin 권한

다시 만들어야 하면 정리 직전 커밋(`8e778fe`)의 코드를 참고합니다. 루트 스택의 state(`gcp-org/terraform.tfstate`)는 비어 있는 상태로 AWS 관리 계정의 state 버킷에 남아 있습니다.

## 남아 있는 것

| 스택 | 실행 계정 | 관리하는 것 |
|---|---|---|
| `bootstrap/` | `admin@soulee.dev` | 조직 관리자의 `orgpolicy.policyAdmin`, 도메인 제한 정책 해제, `alus20x@gmail.com`의 조직 역할 |

비용이 나오지 않는 설정이라 삭제하지 않았습니다. state는 AWS 관리 계정의 org state 버킷(`gcp-org/bootstrap/` 키)에 있으므로, 실행할 때 AWS `mgmt` 프로필도 로그인되어 있어야 합니다.

```bash
aws sso login --sso-session sbh26
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account=admin@soulee.dev)
cd bootstrap && terraform plan
```

## 콘솔과 외부에서 설정한 값

| 위치 | 설정 | 값 |
|---|---|---|
| Cloud Identity Free | 조직 | `soulee.dev`, 관리자 `admin@soulee.dev` |
| Cloudflare DNS (`soulee.dev`) | 도메인 인증 | `google-site-verification` TXT 레코드 |
| Cloud Billing | 결제 계정 | `내 결제 계정 4` (KRW), `alus20x@gmail.com`이 소유하고 조직 밖에 있음. 프로젝트를 삭제한 뒤에도 결제 보고서에서 그동안 나온 비용을 확인할 수 있습니다. |
