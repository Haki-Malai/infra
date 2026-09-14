import {
  to = aws_route53_record.apex_a
  id = "Z1028532234LVOB9E3HEK_hakimalai.com_A"
}

import {
  to = aws_route53_record.apex_aaaa
  id = "Z1028532234LVOB9E3HEK_hakimalai.com_AAAA"
}

import {
  to = aws_route53_record.qr_a
  id = "Z1028532234LVOB9E3HEK_qr.hakimalai.com_A"
}

import {
  to = aws_route53_record.qr_aaaa
  id = "Z1028532234LVOB9E3HEK_qr.hakimalai.com_AAAA"
}

import {
  to = github_repository_ruleset.restrict_branch_writes
  id = "infra:16465508"
}

import {
  to = github_actions_environment_variable.packetloss["dev/AWS_REGION"]
  id = "PACKETLOSS:dev:AWS_REGION"
}

import {
  to = github_actions_environment_variable.packetloss["dev/BUILD_MODE"]
  id = "PACKETLOSS:dev:BUILD_MODE"
}

import {
  to = github_actions_environment_variable.packetloss["dev/SITE_URL"]
  id = "PACKETLOSS:dev:SITE_URL"
}

import {
  to = github_actions_environment_variable.packetloss["dev/VITE_GAME_ENV"]
  id = "PACKETLOSS:dev:VITE_GAME_ENV"
}

import {
  to = github_actions_environment_variable.packetloss["prod/AWS_REGION"]
  id = "PACKETLOSS:prod:AWS_REGION"
}

import {
  to = github_actions_environment_variable.packetloss["prod/BUILD_MODE"]
  id = "PACKETLOSS:prod:BUILD_MODE"
}

import {
  to = github_actions_environment_variable.packetloss["prod/SITE_URL"]
  id = "PACKETLOSS:prod:SITE_URL"
}

import {
  to = github_actions_environment_variable.packetloss["prod/VITE_GAME_ENV"]
  id = "PACKETLOSS:prod:VITE_GAME_ENV"
}
