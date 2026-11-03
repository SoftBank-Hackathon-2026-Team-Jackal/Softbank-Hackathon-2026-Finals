# 클라우드 계정 구조 (v0.1, 2026-11-03)

> 관련 문서: [MVP 설계](./mvp.md) · [CDC 설계](./cdc.md)
> 출발점: 예선 저장소 `one-tatchi-platform`의 `org/` Terraform과 ADR-0001(AWS 계정 구조와 팀 접근 방식)

---

## 1. 결정 요약

| 항목 | 결정 |
|---|---|
| AWS | 예선 때 만든 Organization을 그대로 사용하고, OU와 멤버 계정을 `platform`, `prod`, `sandbox`로 나눔 |
| GCP | 이소울의 개인 계정과 결제 계정으로 새로 구성함. `soulee.dev` 도메인으로 Cloud Identity Free에 가입해 **GCP 조직 리소스를 만들고**, 폴더를 AWS의 OU와 같은 모양으로 나눔. 팀원은 각자의 Google 계정으로 로그인함 |
| 이름 | 예선 이름(`one-tatchi`)은 쓰지 않음. 계정, 폴더, 프로젝트 표시 이름은 `platform`, `prod`, `sandbox`로 통일함 |
| 전역 고유 이름 | GCP 프로젝트 ID와 버킷 이름에는 접두어 `sbh26`을 붙임 |
| Control Tower | 사용하지 않음 (3절 참고) |
| 인증 | 장기 키를 쓰지 않음. 사람은 SSO와 `gcloud` 로그인, 플랫폼은 역할 위임과 Workload Identity Federation을 사용함 |

---

## 2. 설계 원칙

1. **MVP의 env 하나가 AWS 계정 하나 또는 GCP 프로젝트 하나에 대응합니다.** 그래서 Map에 표시하는 단위, 비용을 집계하는 단위, 권한을 나누는 단위, 해커톤이 끝난 뒤 정리하는 단위가 모두 같아집니다.
2. **프로덕션과 샌드박스를 계정과 프로젝트 단위로 분리합니다.** AI 에이전트는 샌드박스에서만 자유롭게 작업하고, 프로덕션은 승인을 거친 Executor만 변경합니다.
3. **플랫폼(컨트롤 플레인)은 관리 대상 env 밖에 둡니다.** 플랫폼이 이전 대상 env 안에 있으면, 그 env를 옮기는 동안 플랫폼도 함께 영향을 받기 때문입니다.
4. **두 클라우드의 계층과 가드레일을 같은 모양으로 맞춥니다.** 이 구조로 "보안과 거버넌스를 모든 환경에서 같은 수준으로 지키는가"라는 본선 질문에 답합니다.

---

## 3. 전체 구조

```
AWS Organization                         GCP Organization (soulee.dev)
├── 관리 계정 (기존)                      ├── 조직 정책: 서울 리전, 서비스 계정 키 생성 금지
│     조직, 결제, Identity Center,        │
│     org state, 조직 CloudTrail          │
├── OU platform  └── platform            ├── 폴더 platform  (필요해지면 추가)
├── OU prod      └── prod (기존 계정)     ├── 폴더 prod      └── sbh26-prod
└── OU sandbox   └── sandbox             └── 폴더 sandbox   └── sbh26-sandbox

온프레미스: 팀원 PC 또는 VM (WireGuard 또는 Tailscale로 연결)
```

### 3.1 env 식별자

이번 데모는 원본과 대상이 모두 프로덕션인 이전 시나리오입니다. 그래서 플랫폼 안에서 쓰는 env 식별자에는 클라우드 이름을 붙입니다. 콘솔에 보이는 계정 이름과 프로젝트 표시 이름은 클라우드가 이미 구분되므로 짧게 둡니다.

| env 식별자 | 위치 | 역할 |
|---|---|---|
| `aws-prod` | AWS 계정 `prod` | 이전할 원본 프로덕션 |
| `gcp-prod` | GCP 프로젝트 `sbh26-prod` | 이전 대상 프로덕션 |
| `onprem` | 팀원 PC 또는 VM | 온프레미스 이전 대상 |
| `aws-sandbox` | AWS 계정 `sandbox` | 에이전트가 AWS 쪽 변경을 시험하는 곳 |
| `gcp-sandbox` | GCP 프로젝트 `sbh26-sandbox` | 에이전트가 GCP 쪽 변경을 시험하는 곳 |
| (env 아님) | AWS 계정 `platform` | 플랫폼 백엔드, 대시보드, Executor, 모든 env의 Terraform state |

### 3.2 단위별 역할과 변경 주체

| 단위 | 들어가는 것 | 변경하는 주체 |
|---|---|---|
| AWS 관리 계정 | 조직, SSO, 조직 단위 감사 로그 | 조직 관리자 한 명이 로컬에서 apply (ADR-0001 유지) |
| `platform` | 플랫폼, Executor, Terraform state 버킷 | 팀원 (Admin) |
| `prod`, `sbh26-prod` | 앱, PostgreSQL, HAProxy, PgBouncer | **Executor만** 변경함. 사람은 ReadOnly 권한과 비상용 Admin 권한만 가짐 |
| `sandbox`, `sbh26-sandbox` | 에이전트가 만든 임시 리소스 | 에이전트 역할 (SCP, 조직 정책, IAM으로 제한) |

---

## 4. 인증 흐름

```
사람 ──SSO──────────▶ 각 AWS 계정
사람 ──gcloud 로그인──▶ 각 GCP 프로젝트

플랫폼 (platform 계정의 IAM 역할)
 ├─ sts:AssumeRole ─────────────────────────▶ prod, sandbox 계정의 executor 역할
 └─ Workload Identity Federation (AWS 공급자) ─▶ GCP executor 서비스 계정
```

- GCP의 Workload Identity Federation은 AWS 역할을 공급자로 직접 지원합니다. 따라서 플랫폼은 서비스 계정 키 없이 AWS 역할만으로 GCP에 접근합니다.
- 샌드박스 컨테이너에는 클라우드 자격 증명을 주입하지 않습니다. 실제 클라우드를 변경하는 작업은 승인을 거친 뒤 Executor가 수행합니다.

---

## 5. 가드레일

| 항목 | AWS | GCP |
|---|---|---|
| 리전 제한 | SCP (예선의 guardrails를 모든 OU에 적용) | 조직 정책 `gcp.resourceLocations` |
| 장기 키 금지 | SSO만 사용, IAM 사용자 생성 금지 (SCP) | 조직 정책 `iam.managed.disableServiceAccountKeyCreation` (새 조직에 기본 적용) |
| 외부 계정 | Identity Center 사용자만 접근 | 팀원이 각자의 Google 계정을 쓰므로 도메인 제한 정책(`iam.allowedPolicyMemberDomains`)을 풂. 대신 IAM 권한을 프로젝트 단위로 좁게 부여함 |
| 샌드박스 제한 | sandbox OU 전용 SCP: IAM 사용자와 액세스 키 생성 금지, 소형 인스턴스만 허용, EKS와 RDS와 NAT Gateway 생성 금지 | sandbox 폴더의 조직 정책과 좁은 서비스 계정 권한 (`compute.instanceAdmin` 수준) |
| 예산 | 계정별 AWS Budgets | 프로젝트별 Billing Budget |
| 감사 로그 | 조직 CloudTrail | Cloud Audit Logs |
| 위협 탐지 | GuardDuty | Security Command Center Standard 등급 |

GuardDuty와 Security Command Center가 낸 결과는 플랫폼이 수집해서 한 화면에 같은 형식으로 보여 줍니다. 킥오프 자료의 질문인 "클라우드마다 다른 보안 기능을 어떻게 통일하고 시각화할 것인가"에 대한 답이 이 화면입니다.

---

## 6. 이름 규칙

| 대상 | 규칙 | 예 |
|---|---|---|
| AWS 계정, OU | 역할 이름만 사용 | `prod`, `sandbox`, `platform` |
| GCP 폴더, 프로젝트 표시 이름 | 역할 이름만 사용 | `prod`, `sandbox` |
| GCP 프로젝트 ID | `sbh26-<역할>`, 이미 사용 중이면 뒤에 문자열을 붙임 | `sbh26-prod` |
| 버킷 | `sbh26-<용도>-<계정 ID 또는 프로젝트 ID>` | `sbh26-tfstate-<계정 ID>` |
| SSO 그룹 | 역할 이름 | `admin`, `readonly` |
| AWS CLI 프로필 | 계정 이름과 같게 둠 | `mgmt`, `platform`, `prod`, `sandbox` |
| 멤버 계정 이메일 | Gmail의 `+` 주소 | `<계정>+sandbox@gmail.com` |

---

## 7. 예선 구조에서 바꾸는 것

> **갱신 (2026-11-03):** 예선이 끝난 뒤 AWS 리소스 대부분이 삭제되어, 아래 표의 계획 대신 Organization만 import하고 나머지는 [`infra/org`](../infra/org)로 새로 만들었습니다. `one-tatchi` 계정은 닫혀 있어 `prod` 계정을 새로 만들었습니다. 자세한 내용은 [작업 기록](./2026-11-03-cloud-setup-log.md) 5절에 있습니다.

| 기존 | 변경 | 방법 |
|---|---|---|
| 멤버 계정 `one-tatchi` | `prod` | 계정 이름만 바꿉니다. 계정 ID와 내부 리소스는 유지됩니다. Terraform 리소스 주소는 `moved` 블록으로 옮깁니다 |
| (없음) | `platform`, `sandbox` 계정과 OU 3개 | `org/`에 리소스를 추가합니다 |
| SSO 그룹 `onetatchi-admin`, `onetatchi-readonly` | `admin`, `readonly` | 그룹을 다시 만들고 계정 할당을 옮깁니다 |
| SCP `one-tatchi-guardrails` | `baseline-guardrails` | 이름을 바꾸고 모든 OU에 연결합니다 |
| (없음) | `sandbox-guardrails` SCP | sandbox OU에만 연결합니다 |
| org state 버킷 `onetatchi-org-tfstate-…` | 그대로 둠 | 버킷 이름은 바꿀 수 없고, 관리 계정 안에서만 쓰므로 옮길 이유가 작습니다 |
| GCP 프로젝트 `one-tatchi-gejkm` | 사용하지 않음 | 소유자와 결제 계정이 다른 팀원에게 있고, 현재 결제가 비활성화되어 있습니다. 소유자에게 정리를 요청합니다 |
| `prod` 계정의 예선 리소스 (EKS 등) | VM 기반으로 다시 구성 | MVP가 VM 기반이고 EKS 컨트롤 플레인 비용이 큽니다. 남은 리소스를 확인한 뒤 정리합니다 |

---

## 8. 검토한 대안

| 대안 | 채택하지 않은 이유 |
|---|---|
| AWS Control Tower | AWS 안에서만 동작해 GCP와 온프레미스에는 적용되지 않습니다. 랜딩 존 구성에 시간이 오래 걸리고 Log Archive와 Audit 계정이 추가로 생기며, 해커톤이 끝난 뒤 해제하기 번거롭습니다. 필요한 기능(SSO, SCP, 예산)은 예선 구조에 이미 있습니다 |
| 계정 하나에 모든 env를 둠 | 에이전트의 실수가 프로덕션에 영향을 줄 수 있고, 비용과 권한을 env별로 나누기 어렵습니다 |
| GCP를 개인 Gmail 계정의 프로젝트로만 구성 | 조직 정책을 쓸 수 없어 AWS의 SCP에 대응하는 수단이 없습니다. 두 클라우드의 가드레일이 비대칭이 됩니다 |
| 예선 GCP 프로젝트 재사용 | 소유자와 결제 계정이 다른 팀원에게 있어 권한 구조를 바꾸기 어렵습니다 |
| 이름에 팀명 유지 (`one-tatchi-prod` 등) | 본선 팀과 저장소가 바뀌었고, 역할 이름만으로 충분히 구분됩니다 |

---

## 9. 다음 작업

1. AWS SSO에 다시 로그인하고 `prod`(기존 `one-tatchi`) 계정에 남은 리소스를 확인합니다.
2. `org/`에 OU, `platform`과 `sandbox` 계정, 이름 변경, SCP를 반영하고 `terraform plan`을 검토합니다. apply는 조직 관리자가 실행합니다.
3. `soulee.dev`로 Cloud Identity Free에 가입하고 DNS TXT 레코드로 도메인을 인증합니다.
4. GCP 조직 정책, 폴더, 프로젝트(`sbh26-prod`, `sbh26-sandbox`)를 만들고 결제 계정을 연결합니다.
5. Executor 역할(AWS)과 서비스 계정(GCP), Workload Identity Federation을 구성합니다.
6. 두 클라우드에 예산 알림, CloudTrail, GuardDuty, Security Command Center를 켭니다.

## 10. 미결정 사항

- [ ] `platform` 계정을 바로 만들지, 처음에는 플랫폼을 로컬에서 실행할지
- [ ] 샌드박스 계정과 프로젝트를 지금 만들지, 샌드박스 범위(MVP 9절)가 정해진 뒤에 만들지
- [ ] 온프레미스 연결 수단으로 WireGuard(MVP 5.1절)와 Tailscale(예선 ADR-0017) 중 무엇을 쓸지
