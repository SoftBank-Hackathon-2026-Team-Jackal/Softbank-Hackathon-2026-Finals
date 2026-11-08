# org

AWS 조직, OU, SCP, Identity Center를 관리하는 스택입니다. 워크로드 계정, 예산, 조직 CloudTrail은 2026-11-08에 정리했습니다(아래 "정리 기록" 참고). 구조와 결정 배경은 [클라우드 계정 구조](../../notes/cloud-structure.md)에 있습니다.

예선 저장소 `one-tatchi-platform`의 `org/`를 바탕으로 작성했습니다.

## 관리하는 것

| 파일 | 내용 |
|---|---|
| `organization.tf` | 조직, 신뢰 서비스(CloudTrail, IAM, SSO), 멤버 계정 루트 자격 증명 중앙 관리, OU 3개 |
| `scp.tf` | `baseline-guardrails`(모든 OU), `sandbox-guardrails`(sandbox OU) |
| `sso.tf` | 권한 세트(`AdministratorAccess`, `ReadOnlyAccess`), 사용자, 그룹, 관리 계정 할당 |
| `state.tf`, `backend.tf` | 이 스택의 state 버킷과 S3 백엔드 |

## 계정과 CLI 프로필

| 계정 | CLI 프로필 | 접근 |
|---|---|---|
| 관리 계정 | `mgmt` | 조직 관리자(`soul.lee`)만 |

워크로드 계정 `platform`, `prod`, `sandbox`는 닫혔으므로 해당 CLI 프로필은 더 이상 쓸 수 없습니다.

SSO 포털 주소는 `terraform output sso_start_url`로 확인합니다.

```bash
aws sso login --sso-session sbh26
aws sts get-caller-identity --profile prod
```

## 콘솔에서 직접 설정한 값

API가 없어 콘솔에서 바꾼 값입니다. 바꾸면 이 표도 함께 고칩니다.

| 위치 | 설정 | 현재 값 |
|---|---|---|
| IAM Identity Center | 인스턴스 | 조직 인스턴스, 서울(`ap-northeast-2`) |
| Identity Center → Settings → Authentication → Standard authentication | Send email OTP for users without a password | 켬 (예선 때 이름은 "Send email OTP for users created from API") |
| Identity Center → Settings → Authentication → Multi-factor authentication | Prompt users for MFA | **Never (disabled)** (2026-11-03) |

**MFA를 끈 대가:** `soul.lee`는 관리 계정의 `AdministratorAccess`를 가지며, SCP는 관리 계정에 적용되지 않습니다. 따라서 조직 전체의 관리자 권한이 비밀번호 하나에 의존합니다. 해커톤 기간의 편의를 위해 감수했으며, 해커톤이 끝나거나 팀원을 추가할 때 "Require them to register an MFA device at sign in"으로 다시 켜는 것을 권장합니다.

## 규칙

- **apply는 조직 관리자가 로컬에서만 실행합니다.** 관리 계정에는 CI(OIDC)를 열지 않습니다.
- **`team.auto.tfvars`는 커밋하지 않습니다.** 계정과 팀원의 이메일이 들어 있습니다. 형식은 `team.auto.tfvars.example`을 참고합니다.
- 루트 세션(`aws login --profile root-bootstrap`)은 처음 구성할 때만 사용했고, 2026-11-03에 `aws logout`으로 정리했습니다. 이후에는 `mgmt` 프로필을 사용합니다.

## 팀원 추가

`team.auto.tfvars`의 `users`에 항목을 추가하고 `terraform apply`를 실행합니다. `role`에는 `admin` 또는 `readonly`를 씁니다. username(키)을 바꾸면 사용자를 지우고 새로 만드므로 주의합니다. 지금은 워크로드 계정이 없으므로, 사용자를 추가해도 접근할 수 있는 계정은 없습니다.

## 처음부터 다시 만들 때

1. 콘솔에서 Identity Center를 켜고, Standard authentication의 "Send email OTP for users without a password"를 켭니다. 이 설정이 꺼져 있으면 API로 만든 사용자는 첫 로그인과 비밀번호 재설정에서 MFA 오류가 납니다.
2. `aws login --profile root-bootstrap`으로 루트 임시 자격 증명을 받습니다.
3. `backend.tf`의 블록을 주석으로 처리하고, 남아 있는 조직이 있으면 `import` 블록을 추가합니다.
4. `terraform init`, `terraform plan`, `terraform apply`를 실행합니다.
5. 주석을 풀고 `terraform init -migrate-state`로 state를 S3로 옮깁니다.

## 정리 기록 (2026-11-08)

해커톤 본선이 끝난 뒤, 대상을 지정한 `terraform destroy`와 `apply`로 아래 리소스를 삭제하고 코드에서도 지웠습니다.

- 워크로드 계정 `platform`(367123691646), `prod`(714066696240), `sandbox`(608379566120): 닫혀서 SUSPENDED 상태입니다. 2027-02-06 무렵까지는 AWS Support를 통해 다시 열 수 있고, 같은 이메일은 다시 쓸 수 없습니다.
- 계정별 예산, 조직 CloudTrail과 로그 버킷
- 워크로드 계정에 대한 그룹 할당, 팀원 SSO 사용자 3명

남긴 것은 조직, OU, SCP, Identity Center(조직 관리자 `soul.lee`와 관리 계정 할당, 권한 세트, 그룹), 이 스택의 state 버킷입니다. 관리 계정에 로그인할 수 있으므로 Cost Explorer에서 닫힌 계정의 그동안 비용도 계속 확인할 수 있습니다.

다시 만들어야 하면 정리 직전 커밋(`8e778fe`)의 `accounts.tf`, `budgets.tf`, `cloudtrail.tf`와 `sso.tf`의 계정 할당 코드를 참고합니다.
