# SCP는 관리 계정에는 적용되지 않습니다. 모든 워크로드 OU에 baseline을, sandbox OU에는 추가 제한을 연결합니다.
# 서비스 연결 역할(예: Auto Scaling)에는 SCP가 적용되지 않으므로, 인스턴스 유형 제한은 사람과 에이전트가 직접 띄우는 경우만 막습니다.

data "aws_iam_policy_document" "baseline" {
  statement {
    sid    = "DenyOutsideSeoul"
    effect = "Deny"
    # 글로벌 서비스(us-east-1로 호출되는 것)는 예외입니다.
    not_actions = [
      "account:*",
      "acm:*",
      "billing:*",
      "budgets:*",
      "ce:*",
      "cloudfront:*",
      "cur:*",
      "health:*",
      "iam:*",
      "identitystore:*",
      "organizations:*",
      "pricing:*",
      "route53:*",
      "route53domains:*",
      "s3:GetBucketLocation",
      "s3:ListAllMyBuckets",
      "sso:*",
      "sts:*",
      "support:*",
      "waf:*",
      "wafv2:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid       = "DenyLeaveAndCloseAccount"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization", "account:CloseAccount"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyLongTermCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "LimitEc2InstanceTypes"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotLike"
      variable = "ec2:InstanceType"
      values   = ["t3.*", "t3a.*", "t4g.*", "m6i.large", "m7i.large", "c6i.large"]
    }
  }

  statement {
    sid       = "LimitRdsInstanceClasses"
    effect    = "Deny"
    actions   = ["rds:CreateDBInstance", "rds:ModifyDBInstance"]
    resources = ["*"]

    condition {
      test     = "StringNotLike"
      variable = "rds:DatabaseClass"
      values   = ["db.t3.*", "db.t4g.*"]
    }
  }
}

# AI 에이전트가 시험하는 계정입니다. 비용이 큰 리소스와 소형이 아닌 인스턴스를 막습니다.
data "aws_iam_policy_document" "sandbox" {
  statement {
    sid    = "DenyExpensiveServices"
    effect = "Deny"
    actions = [
      "eks:CreateCluster",
      "rds:CreateDBInstance",
      "rds:CreateDBCluster",
      "ec2:CreateNatGateway",
      "elasticloadbalancing:CreateLoadBalancer",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "SmallInstancesOnly"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotLike"
      variable = "ec2:InstanceType"
      values   = ["t3.micro", "t3.small", "t4g.micro", "t4g.small"]
    }
  }
}

resource "aws_organizations_policy" "baseline" {
  name        = "baseline-guardrails"
  description = "서울 리전만, 조직 탈퇴와 계정 해지 금지, 장기 자격 증명 금지, EC2와 RDS 유형 제한"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.baseline.json
}

resource "aws_organizations_policy" "sandbox" {
  name        = "sandbox-guardrails"
  description = "sandbox OU 전용: 비용이 큰 서비스 금지, 소형 인스턴스만 허용"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.sandbox.json
}

resource "aws_organizations_policy_attachment" "baseline" {
  for_each = local.workloads

  policy_id = aws_organizations_policy.baseline.id
  target_id = aws_organizations_organizational_unit.this[each.key].id
}

resource "aws_organizations_policy_attachment" "sandbox" {
  policy_id = aws_organizations_policy.sandbox.id
  target_id = aws_organizations_organizational_unit.this["sandbox"].id
}
