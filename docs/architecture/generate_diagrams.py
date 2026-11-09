"""Architecture diagrams as code, drawn with the official AWS / Kubernetes icons.

Regenerate (needs Graphviz: `brew install graphviz`):

    cd docs/architecture && uv run --no-project --with diagrams python generate_diagrams.py
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.general import Users
from diagrams.aws.management import Cloudwatch
from diagrams.aws.network import ALB, InternetGateway, NATGateway, Route53
from diagrams.aws.security import KMS, SecretsManager
from diagrams.aws.storage import S3
from diagrams.generic.blank import Blank
from diagrams.k8s.compute import Pod
from diagrams.k8s.network import Service
from diagrams.k8s.podconfig import Secret
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.monitoring import Prometheus
from diagrams.onprem.vcs import Github
from diagrams.saas.alerting import Pagerduty

GRAPH = {"fontsize": "20", "pad": "0.4", "nodesep": "0.6", "ranksep": "0.9"}
AZS = ("ap-south-1a", "ap-south-1b", "ap-south-1c")


def aws_architecture() -> None:
    """Production layout: 3 AZs, three subnet tiers, NAT per AZ, Multi-AZ RDS."""
    with Diagram(
        "tdb-bookings on AWS (prod)",
        filename="aws-architecture",
        show=False,
        direction="LR",
        graph_attr={**GRAPH, "ranksep": "1.4", "newrank": "true"},
    ):
        users = Users("Clients")
        dns = Route53("Route 53")

        with Cluster("AWS Cloud · Region ap-south-1"):
            with Cluster("Regional services"):
                secrets = SecretsManager("Secrets Manager\nDB master password")
                kms = KMS("KMS\nstorage + secret keys")
                logs = Cloudwatch("CloudWatch\nflow logs, RDS logs")
                state = S3("S3\nTerraform state")

            with Cluster("VPC 10.0.0.0/16  (EKS runs in the app subnets; outside P4 scope)"):
                igw = InternetGateway("Internet Gateway")
                alb = ALB("Application LB\nspans 3 public subnets")
                nats, pods, dbs = [], [], []
                for i, az in enumerate(AZS):
                    with Cluster(f"AZ {az}"):
                        with Cluster(f"Public 10.0.{i}.0/24"):
                            nats.append(NATGateway(f"NAT GW {az[-1]}"))
                        with Cluster(f"Private app 10.0.{10 + i}.0/24"):
                            pods.append(Pod("tdb-bookings pod\n:8080"))
                        with Cluster(f"Private DB 10.0.{20 + i}.0/24"):
                            if i == 0:
                                dbs.append(RDSPostgresqlInstance("RDS PostgreSQL\nprimary"))
                            elif i == 1:
                                dbs.append(RDSPostgresqlInstance("RDS standby\n(Multi-AZ, sync)"))
                            else:
                                dbs.append(Blank("no instance\n(in DB subnet group)"))

        users >> Edge(label="HTTPS") >> dns >> igw >> alb
        for i, (pod, nat) in enumerate(zip(pods, nats, strict=True)):
            alb >> Edge(label=":8080") >> pod
            pod >> Edge(label="5432 TLS", color="darkgreen") >> dbs[0]
            pod >> Edge(label="egress", style="dashed", color="gray") >> nat
            if i:
                dbs[i - 1] - Edge(style="invis") - dbs[i]
        dbs[0] >> Edge(label="sync replication", color="firebrick", style="bold") >> dbs[1]
        dbs[0] >> Edge(style="dotted", color="gray") >> [secrets, logs]
        secrets >> Edge(style="dotted", color="gray") >> kms
        _ = state


def data_flow() -> None:
    """Request path, secret delivery path and observability path."""
    with Diagram("Data flow", filename="data-flow", show=False, direction="LR", graph_attr=GRAPH):
        users = Users("Client")
        alb = ALB("ALB")

        with Cluster("Kubernetes namespace tdb-bookings"):
            svc = Service("Service")
            pod = Pod("tdb-bookings pod\nFastAPI")
            k8s_secret = Secret("Secret\nDATABASE_URL")

        rds = RDSPostgresqlInstance("RDS PostgreSQL")
        sm = SecretsManager("Secrets Manager")

        with Cluster("Observability"):
            prom = Prometheus("Prometheus\nSLO recording + alert rules")
            oncall = Pagerduty("Alertmanager →\non-call")

        users >> Edge(label="1. GET /bookings") >> alb >> Edge(label="2") >> svc >> pod
        pod >> Edge(label="3. query (future)", color="darkgreen") >> rds
        pod >> Edge(label="4. JSON response", style="dashed") >> users
        sm >> Edge(label="External Secrets\nOperator sync", color="purple") >> k8s_secret
        k8s_secret >> Edge(label="env var at start", color="purple") >> pod
        prom >> Edge(label="scrape /metrics", color="orange") >> pod
        prom >> Edge(label="burn-rate alert\n+ runbook_url", color="red") >> oncall


def network_flow() -> None:
    """Security-group chain and route tables: what can reach what."""
    with Diagram(
        "Network flow and boundaries",
        filename="network-flow",
        show=False,
        direction="LR",
        graph_attr=GRAPH,
    ):
        internet = Users("Internet")
        igw = InternetGateway("IGW")

        with Cluster("Public subnets · route 0.0.0.0/0 → IGW"):
            alb = ALB("sg-alb\nin: 443 from 0.0.0.0/0")
            nat = NATGateway("NAT GW (one per AZ)")

        with Cluster("Private app subnets · route 0.0.0.0/0 → NAT in same AZ"):
            pod = Pod("sg-app\nin: 8080 from sg-alb only")

        with Cluster("Private DB subnets · local routes only, no internet path"):
            rds = RDSPostgresqlInstance("sg-db\nin: 5432 from sg-app only\nforce_ssl=1, not public")

        internet >> Edge(label="443") >> igw >> alb
        alb >> Edge(label="8080") >> pod
        pod >> Edge(label="5432 TLS", color="darkgreen") >> rds
        pod >> Edge(label="egress (image pulls, AWS APIs)", style="dashed") >> nat >> igw
        internet >> Edge(label="blocked: no route, no SG rule", color="red", style="dashed") >> rds


def cicd_flow() -> None:
    """From pull request to a traceable image in GHCR."""
    with Diagram("CI/CD flow", filename="cicd-flow", show=False, direction="LR", graph_attr=GRAPH):
        repo = Github("Pull request\n→ main")

        with Cluster("GitHub Actions: every PR"):
            quality = GithubActions("ruff · mypy · pytest")
            sec = GithubActions("pip-audit · gitleaks\nhadolint")
            image = GithubActions("buildx build\n+ Trivy (CRITICAL = fail)")
            iac = GithubActions(
                "helm lint · kubeconform\nterraform validate · tflint\ncheckov · promtool"
            )

        with Cluster("On merge to main"):
            publish = GithubActions("build → scan → push\nSBOM + provenance")
            ghcr = Github("GHCR\n:sha-<commit> · :main")

        repo >> [quality, sec, image, iac]
        repo >> Edge(label="merge") >> publish >> Edge(label="only if scan passes") >> ghcr


if __name__ == "__main__":
    aws_architecture()
    data_flow()
    network_flow()
    cicd_flow()
