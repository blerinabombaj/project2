# modules/eks/main.tf
#
# Creates everything needed to run a production-grade EKS cluster:
#   - VPC with public + private subnets across 2 AZs
#   - EKS control plane
#   - Managed node group (the EC2 instances that run your pods)
#   - IAM roles for the cluster and nodes
#
# WHY USE COMMUNITY MODULES?
#   The raw AWS resources for EKS are extremely verbose — a proper setup
#   requires 15-20 individual resources. The community modules
#   (terraform-aws-modules/vpc and terraform-aws-modules/eks) are
#   maintained by AWS and the community, battle-tested, and used by
#   thousands of companies. Real teams use them.
#
#   In step 3 (Terragrunt), you'll call THIS module from per-environment
#   configs, passing different variables for dev/staging/prod.

# ── VPC ────────────────────────────────────────────────────────────────────────
#
# WHY DO WE NEED A CUSTOM VPC?
#   EKS technically works in the default VPC, but that's considered bad practice.
#   You want:
#     - Private subnets for worker nodes (not directly internet-accessible)
#     - Public subnets for load balancers only
#     - NAT Gateway so private nodes can reach the internet (to pull images, etc.)
#     - Proper subnet tags so EKS and the AWS load balancer controller know
#       which subnets to use
#
# SUBNETS ACROSS 2 AZs:
#   If you put everything in one AZ and that AZ goes down, so does your app.
#   2 AZs gives you basic availability. Prod would use 3.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = "10.0.0.0/16" # 65,536 IPs — plenty of room

  # Use the first 2 available AZs in the region automatically
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Private subnets — where worker nodes live
  # Nodes here cannot be reached directly from the internet
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # Public subnets — where load balancers live
  # Only the ALB/NLB sits here, not your pods
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  # NAT Gateway allows private subnet instances to initiate outbound
  # internet connections (e.g. pulling images from ECR or Docker Hub)
  # without being directly reachable from the internet.
  # single_nat_gateway = true saves cost (one NAT per region instead of per AZ).
  # For prod you'd use one per AZ for redundancy.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # These tags are REQUIRED by EKS — without them, EKS can't find the right
  # subnets to place load balancers in. Don't remove them.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ── EKS Cluster ────────────────────────────────────────────────────────────────
#
# The EKS control plane (API server, etcd, scheduler, controller manager)
# is managed by AWS — you never SSH into it. You only manage worker nodes.
#
# COST REMINDER: $0.10/hr for the control plane regardless of what's running.
# Always `terraform destroy` when not using it.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project_name}-${var.environment}"
  cluster_version = var.cluster_version

  # Place the cluster in our VPC, with the control plane endpoint accessible
  # from the internet (so you can kubectl from your laptop).
  # In a real prod setup you'd set cluster_endpoint_public_access = false
  # and access it via VPN, but for a learning project public is fine.
  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnet_ids
  cluster_endpoint_public_access = true

  # CLUSTER ADD-ONS
  # These are core Kubernetes components managed by EKS.
  # Without them, things like DNS (CoreDNS) and pod networking (kube-proxy) don't work.
  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true } # needed for IRSA in step 3
  }

  # ── Managed Node Group ──────────────────────────────────────────────────────
  #
  # A managed node group is a set of EC2 instances that EKS manages for you.
  # EKS handles: OS patching, node replacement, scaling events.
  # You just specify the instance type and desired count.
  #
  # "Managed" vs "self-managed": managed groups are the standard choice.
  # Self-managed is for when you need custom AMIs or very specific configs.

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_count
      max_size     = var.node_max_count
      desired_size = var.node_desired_count

      # Nodes live in private subnets — not directly internet-accessible.
      # They reach the internet via the NAT Gateway for pulling images etc.
      subnet_ids = module.vpc.private_subnet_ids

      # IAM policies attached to the node role — the minimum required for EKS nodes.
      # AmazonEKSWorkerNodePolicy    — lets the node join the cluster
      # AmazonEKS_CNI_Policy         — lets the VPC CNI assign pod IPs
      # AmazonEC2ContainerRegistryReadOnly — lets the node pull from ECR
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        # SSM lets you shell into nodes without opening SSH ports — more secure
      }
    }
  }

  # Allow your laptop's kubectl to access the cluster.
  # This grants cluster-admin to the IAM identity running terraform apply.
  enable_cluster_creator_admin_permissions = true
}

# ── Data sources ────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  # Only use AZs that are available to our account (some AZs are opt-in only)
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
