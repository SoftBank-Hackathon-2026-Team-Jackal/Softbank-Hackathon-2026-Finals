# 클라우드 설정 작업 기록 (2026-11-03)

> 관련 문서: [클라우드 계정 구조](./cloud-structure.md)

---

## 1. 오늘 결정한 것

| 항목 | 결정 | 근거 |
|---|---|---|
| Control Tower | 사용하지 않음 | AWS 안에서만 동작하고, 구성과 해제에 시간이 많이 듭니다. 필요한 기능은 Organizations, SSO, SCP로 충분합니다 |
| 계정 분리 | 예선처럼 가벼운 멤버 계정으로 나눔 | 예선 ADR-0001의 방식을 이어 갑니다 |
| 이름 | `one-tatchi`를 버리고 `platform`, `prod`, `sandbox`를 사용함 | 역할이 이름에 바로 드러납니다 |
| 전역 고유 이름의 접두어 | `sbh26` | GCP 프로젝트 ID와 버킷 이름은 전 세계에서 고유해야 합니다 |
| GCP 계정 | 이소울의 개인 계정과 결제 계정으로 새로 구성함 | 예선 프로젝트는 소유자와 결제 계정이 다른 팀원에게 있습니다 |
| GCP 조직 | `soulee.dev`로 Cloud Identity Free에 가입해 조직을 만듦 | AWS의 SCP에 대응하는 조직 정책을 쓰기 위해서입니다 |

자세한 구조는 [클라우드 계정 구조](./cloud-structure.md)에 정리했습니다.

---

## 2. 확인한 현재 상태

### 2.1 로컬 도구

| 항목 | 상태 |
|---|---|
| aws-cli | 2.37.5 설치됨 |
| gcloud | 588.0.0 설치됨, `alus20x@gmail.com`으로 로그인됨 |
| terraform | 설치됨 |
| GCP ADC (`application-default`) | 없음. Terraform을 쓰기 전에 `gcloud auth application-default login`이 필요합니다 |

### 2.2 AWS

- `~/.aws/config`에 예선 때 만든 `onetatchi` SSO 프로필이 남아 있습니다.
- `aws sso login --profile onetatchi`가 `invalid_request` 오류로 실패합니다.
- 원인을 확인한 결과, 예선 때 쓰던 SSO 포털 주소의 DNS 조회 결과가 비어 있었습니다. Identity Center 인스턴스가 삭제된 것입니다. 로컬 SSO 캐시의 클라이언트 등록 정보는 2027년 1월까지 유효하므로 캐시 문제는 아닙니다.
- 이소울이 **예선이 끝난 뒤 AWS 리소스를 모두 삭제했다**고 확인했습니다. Organization, 멤버 계정 `one-tatchi`, org state 버킷이 남아 있는지는 아직 확인하지 못했습니다.

### 2.3 GCP

- 예선 프로젝트 `one-tatchi-gejkm`은 결제가 비활성화되어 있습니다(`billingEnabled: False`).
- 이 프로젝트는 사용하지 않고, 새 조직과 프로젝트를 만듭니다.

### 2.4 GitHub

- 팀 조직 `SoftBank-Hackathon-2026-Team-Jackal`에 이 저장소를 비공개로 만들고 push했습니다.
- 같은 조직에 팀원이 만든 애플리케이션 저장소 `cloud-migration-platform`이 있습니다. 그 저장소의 `infra/terraform`에는 README만 있어서 이 문서와 충돌하지 않습니다.

---

## 3. 막힌 것

### 3.1 브라우저 자동화로 AWS 콘솔 작업 불가

Claude in Chrome으로 AWS 콘솔(`console.aws.amazon.com`)을 조작하려 했지만, 두 번 모두 권한 요청 안내 없이 `Permission denied`가 반환되었습니다. 확장 프로그램이 이 도메인을 막고 있는 것으로 보입니다. 공식 문서에 따르면 Anthropic의 사이트 안전 검사나 민감 사이트 분류에 해당하는 사이트는 사용자가 허용해도 계속 막힙니다.

따라서 루트 계정이 필요한 콘솔 작업은 사람이 직접 진행합니다.

---

## 4. 다음 작업

> **갱신 (2026-11-03 오후):** 아래 4.1과 4.2의 1~4단계를 마쳤습니다. 결과는 5절에 있습니다.

### 4.1 사람이 직접 할 일 (루트 계정, 콘솔)

1. 루트로 AWS 콘솔에 로그인하고 리전을 서울(ap-northeast-2)로 선택합니다.
2. IAM Identity Center에서 **Enable**을 누릅니다. Organization이 없으면 이때 함께 만들어집니다.
3. **Users**에서 `soul.lee` 사용자를 만들고, 이메일로 받은 링크에서 비밀번호를 정합니다.
4. `AdministratorAccess` 권한 세트를 만들고 관리 계정에 `soul.lee`를 할당합니다.
5. **Settings**에서 새 AWS access portal URL을 확인합니다.

루트 액세스 키는 발급하지 않습니다.

### 4.2 그 뒤에 이어서 할 일

1. 새 포털 URL로 CLI 프로필을 `mgmt`로 다시 만들고 로그인을 확인합니다.
2. Organization, 멤버 계정, org state 버킷, SCP, 예산 중 무엇이 남아 있는지 확인합니다.
3. 확인 결과에 맞춰 [클라우드 계정 구조](./cloud-structure.md) 7절을 고칩니다. 멤버 계정을 닫았다면 `prod` 계정을 새로 만들어야 하고, 닫은 계정의 이메일은 다시 쓸 수 없습니다.
4. 예선 저장소의 `org/` Terraform을 출발점으로 OU, 계정, SSO, SCP, 예산을 다시 구성합니다.
5. GCP는 Cloud Identity 가입, 조직 정책, 폴더, 프로젝트, 결제 계정 연결 순서로 진행합니다.

---

## 5. AWS 구성 결과

### 5.1 진행 방법

- 콘솔 대신 `aws login --profile root-bootstrap`으로 루트 임시 자격 증명을 받았습니다. 이 명령은 액세스 키를 만들지 않으며, 세션은 최대 12시간 동안 유효합니다.
- Identity Center 조직 인스턴스는 API로 만들 수 없어서(`CreateInstance`는 관리 계정에서 거부됨) 콘솔에서 켰습니다. "Send email OTP for users created from API" 설정도 콘솔에서 켰습니다.
- 나머지는 모두 [`infra/org`](../infra/org) Terraform으로 만들었습니다.

### 5.2 조회한 기존 상태

| 항목 | 상태 |
|---|---|
| Organization | 남아 있음. Terraform으로 import함 |
| 멤버 계정 `one-tatchi` | SUSPENDED (닫힘). 다시 쓸 수 없음 |
| OU, SCP(기본 정책 제외), Identity Center, S3 버킷, 예산, CloudTrail | 없음 |
| 루트의 SCP 정책 유형 | 꺼져 있었음. `describe-organization`의 `AvailablePolicyTypes`는 더 이상 쓰이지 않는 필드라서 켜져 있는 것처럼 보였음 |
| Route53 호스팅 존 | 없음. `soulee.dev`의 DNS를 지금 어디에서 관리하는지 확인이 필요함 (GCP Cloud Identity 도메인 인증에 필요) |

### 5.3 apply 결과

`Resources: 1 imported, 42 added, 1 changed, 0 destroyed.` state는 `sbh26-org-tfstate-…` 버킷으로 옮겼고, 다시 실행한 plan에는 변경 사항이 없습니다.

| 만든 것 | 내용 |
|---|---|
| OU와 계정 | `platform`, `prod`, `sandbox` |
| SCP | `baseline-guardrails`(세 OU), `sandbox-guardrails`(sandbox OU) |
| Identity Center | 권한 세트 2개, 그룹 `admin`과 `readonly`, 사용자 `soul.lee` |
| 예산 | platform $50, prod $100, sandbox $30 |
| 감사 로그 | 조직 CloudTrail `org-trail` |

로컬 `~/.aws/config`에는 `sbh26` SSO 세션과 `mgmt`, `platform`, `prod`, `sandbox` 프로필을 만들었고, 쓸 수 없게 된 `onetatchi` 프로필은 지웠습니다.

### 5.4 남은 일

1. ~~`soul.lee`의 첫 SSO 로그인~~ 완료. 네 프로필 모두 동작하고, sandbox에서 us-east-1 요청이 SCP에 막히는 것을 확인함
2. ~~`aws logout --profile root-bootstrap`~~ 완료
3. ~~팀원 추가~~ 완료. `seungcheol.park`, `minseo.kim`, `sangheon.lee`를 `admin` 그룹에 추가함 (6절 참고)
4. GuardDuty: 보류. 보안 시각화 화면을 만들 때 Security Command Center와 함께 켬 (6절 참고)
5. GCP 구성: 진행 중 (7절 참고)

### 5.5 첫 로그인에서 막힌 것

| 증상 | 원인과 해결 |
|---|---|
| `You are required to provide multi-factor authentication (MFA) that you do not have.` (로그인과 비밀번호 재설정 모두) | Standard authentication의 "Send email OTP for users without a password"가 꺼져 있었습니다. API로 만든 사용자는 비밀번호가 없어 이메일 OTP로 본인을 확인해야 합니다. 이 설정을 켜자 해결되었습니다. 설정 이름이 예선 때("users created from API")와 달라졌습니다 |
| MFA 필수 | Prompt users for MFA를 Never (disabled)로 바꿨습니다. 감수한 위험은 [`infra/org/README.md`](../infra/org/README.md)에 적었습니다 |

---

## 6. 팀원과 GuardDuty

### 6.1 Identity Center 팀원 추가

| 이름 | username | 그룹 |
|---|---|---|
| 박승철 | `seungcheol.park` | `admin` |
| 김민서 | `minseo.kim` | `admin` |
| 이상헌 | `sangheon.lee` | `admin` |

- Terraform으로 추가했습니다 (`6 added, 0 changed, 0 destroyed`). 실제 이메일은 커밋하지 않는 `team.auto.tfvars`에만 있습니다.
- **API로 만든 사용자에게는 초대 메일이 가지 않습니다.** 팀원은 포털에 username을 입력하면 이메일 OTP를 받아 비밀번호를 정할 수 있습니다. 포털 주소, username, CLI 설정을 담은 안내문을 Slack으로 공유하는 것이 초대를 대신합니다.

### 6.2 GuardDuty를 보류한 이유

- 인프라 구성의 전제 조건이 아니고, MVP의 보안 점검은 `baseline_check.py`가 맡습니다.
- 실제 위협이 없는 계정에서는 탐지 결과가 거의 나오지 않으므로, 데모에 쓰려면 샘플 탐지 결과(`create-sample-findings`)가 필요합니다.
- 킥오프 질문 2번(GuardDuty와 Security Command Center를 통일해서 시각화)에 답하는 화면을 만들 때 조직 단위로 켭니다.

---

## 7. GCP 구성 (진행 중)

### 7.1 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 팀원 로그인 | **각자의 Google 계정**을 프로젝트 IAM에 추가함 | 팀원이 새 계정을 관리하지 않아도 되고, 초대 절차가 없습니다 |
| 대안 | `soulee.dev` 계정을 팀원마다 발급 (채택하지 않음) | 도메인 제한 정책을 유지할 수 있지만 계정 발급과 비밀번호 전달이 필요합니다 |
| 조직 관리자 | `admin@soulee.dev`는 부트스트랩과 비상시에만 사용하고, 평소에는 `alus20x@gmail.com`으로 작업함 | |
| 이상헌 님 계정 | `shkm1420@gmail.com` 사용 | GCP IAM에는 Google 계정만 추가할 수 있어서 Naver 대신 Gmail을 씁니다 |

### 7.2 확인한 초기 상태

| 항목 | 상태 |
|---|---|
| `soulee.dev` DNS | Cloudflare에서 관리 중. 메일은 Cloudflare Email Routing으로 받음 |
| 기존 GCP 조직 | 없었음 |
| 결제 계정 | 기존 4개 모두 닫혀 있음. **새 결제 계정이 필요함** |

### 7.3 진행한 것

1. Cloud Identity Free 가입: 관리자 `admin@soulee.dev`, 도메인 `soulee.dev`
2. 도메인 인증: Cloudflare DNS에 `google-site-verification` TXT 레코드 추가
3. 조직 생성 확인: `soulee.dev` (ID `994714599350`, 고객 ID `C0284wz1e`)
4. `gcloud auth login admin@soulee.dev`
5. `admin@soulee.dev`로 GCP Console에 접속하면 "지금은 Google Cloud Console을 로드할 수 없습니다" 오류가 났습니다. 상태 페이지에는 장애가 없었습니다. CLI는 정상적으로 동작합니다

### 7.4 새 조직에 기본으로 적용된 정책 (secure by default)

| 제약 조건 | 의미 | 처리 |
|---|---|---|
| `iam.allowedPolicyMemberDomains` | `soulee.dev` 외부 계정을 IAM에 추가하지 못함 | **풀어야 함.** 팀원이 Gmail과 Naver 계정을 쓰기 때문입니다 |
| `iam.managed.disableServiceAccountKeyCreation` | 서비스 계정 키 생성 금지 | 유지 (구조 문서 5절과 같음) |
| `iam.disableServiceAccountKeyUpload` | 서비스 계정 키 업로드 금지 | 유지 |
| `iam.automaticIamGrantsForDefaultServiceAccounts` | 기본 서비스 계정에 Editor 자동 부여 금지 | 유지 |
| `storage.uniformBucketLevelAccess` | 버킷 단위 권한만 허용 | 유지 |
| `essentialcontacts.managed.allowedContactDomains` | 중요 연락처를 조직 도메인으로 제한 | 유지 |
| `compute.managed.restrictProtocolForwardingCreationForTypes` | 프로토콜 전달 유형 제한 | 유지 |

### 7.5 gcloud로 직접 바꾼 것 (Terraform 밖)

부트스트랩을 `gcloud`로 시도했고, 아래 두 가지가 적용되어 있었습니다. 이후 [`infra/gcp-org/bootstrap`](../infra/gcp-org/bootstrap)으로 둘 다 import했습니다.

| 변경 | 내용 |
|---|---|
| `admin@soulee.dev`에 `roles/orgpolicy.policyAdmin` 부여 | `organizationAdmin`에는 조직 정책을 바꾸는 권한이 없습니다 |
| `iam.allowedPolicyMemberDomains`를 `allowAll: true`로 변경 | 10:38:30 UTC에 적용됨 |

처음 시도에서는 `admin@soulee.dev`에 `orgpolicy.policyAdmin`이 없어 정책 변경이 실패했고, 그 때문에 Gmail 계정에 조직 역할을 주는 작업도 모두 실패했습니다. 스크립트가 실패 여부와 관계없이 "granted"를 출력해서 성공한 것처럼 보였으므로, 결과는 반드시 다시 조회해서 확인해야 합니다.

### 7.6 남은 일

1. `alus20x@gmail.com`으로 결제 계정 `sbh26` 생성 (사람이 직접)
2. ~~`infra/gcp-org/bootstrap`~~ 완료 (`2 imported, 4 added`). 7.5의 두 변경을 import하고, `alus20x@gmail.com`에 `organizationAdmin`, `folderAdmin`, `projectCreator`, `orgpolicy.policyAdmin`을 부여함
3. `infra/gcp-org` 본 스택: 코드 작성과 `validate`까지 완료. 결제 계정 ID를 받으면 plan과 apply를 진행함
   - 폴더 `prod`, `sandbox`와 프로젝트 `sbh26-prod`, `sbh26-sandbox`
   - 조직 정책: 서울 리전만 허용 (`gcp.resourceLocations`)
   - 예산 알림, API 활성화, 팀원 IAM
   - state는 AWS 관리 계정의 state 버킷에 `gcp-org/` 키로 저장
4. ~~이상헌 님의 Google 계정 확인~~ `shkm1420@gmail.com`을 쓰기로 함
