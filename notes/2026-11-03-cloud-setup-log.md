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
