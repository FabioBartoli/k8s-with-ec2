resource "aws_key_pair" "k8s_key" {
  key_name   = var.key_name
  public_key = var.public_key
}

resource "aws_security_group" "this" {
  count = var.instance_count

  vpc_id = var.vpc_id

  dynamic "ingress" {
    for_each = var.security_group_rules
    content {
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  dynamic "egress" {
    for_each = var.security_group_rules
    content {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = {
    Name = "PICK-K8S-SG-Instance-${count.index + 1}"
  }
}

resource "aws_subnet" "k8s_subnet" {
  vpc_id            = var.vpc_id
  cidr_block        = var.k8s_subnet_cidr
  availability_zone = var.k8s_subnet_az

  map_public_ip_on_launch = true

  tags = {
    Name = "PICK-K8S-Subnet"
  }
}

resource "aws_instance" "control_plane" {
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.k8s_key.key_name
  subnet_id     = aws_subnet.k8s_subnet.id

  root_block_device {
    volume_size = var.volume_cp_size
  }

  vpc_security_group_ids = [aws_security_group.this[0].id]

  tags = {
    Name = "PICK-K8S-Control-Plane"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOF
      cat <<EOF2 | sudo tee /etc/modules-load.d/k8s.conf
      overlay
      br_netfilter
      EOF2
      sudo modprobe overlay
      sudo modprobe br_netfilter
      cat <<EOF2 | sudo tee /etc/sysctl.d/k8s.conf
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      EOF2
      sudo sysctl --system
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
      sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg unzip nfs-kernel-server nfs-common bash-completion
      unzip awscliv2.zip
      sudo ./aws/install
      mkdir -p ~/.aws
      echo "[default]" | tee ~/.aws/config
      echo "aws_access_key_id=${var.AWS_ACCESS_KEY_ID}" | tee -a ~/.aws/config
      echo "aws_secret_access_key=${var.AWS_SECRET_ACCESS_KEY}" | tee -a ~/.aws/config
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
      sudo apt-get update
      sudo apt-get install -y kubelet kubeadm kubectl
      sudo apt-mark hold kubelet kubeadm kubectl
      sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update && sudo apt-get install -y containerd.io
      sudo containerd config default | sudo tee /etc/containerd/config.toml
      sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
      sudo systemctl restart containerd
      sudo systemctl enable --now kubelet
      sudo kubeadm init --pod-network-cidr=10.10.0.0/16 --apiserver-advertise-address=${aws_instance.control_plane.private_ip}
      mkdir -p $HOME/.kube
      sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
      sudo chown $(id -u):$(id -g) $HOME/.kube/config
      ################ INSTALAR AUTOCOMPLETE E ALIAS ######################
      kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
      echo 'alias k=kubectl' >>~/.bashrc
      echo 'complete -F __start_kubectl k' >>~/.bashrc
      #####################################################################
      JOIN_COMMAND=$(kubeadm token create --print-join-command)
      aws ssm put-parameter --name "k8s_join_command" --value "$JOIN_COMMAND" --type "String" --overwrite
      kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml
      ################ CRIANDO O NFS ######################
      sudo mkdir /mnt/nfs
      sudo chown $(id -u):$(id -g) /mnt/nfs
      cat <<EOF2 | sudo tee /etc/exports
      /mnt/nfs   ${var.k8s_subnet_cidr}(rw,sync,no_root_squash,no_subtree_check)
      EOF2
      sudo exportfs -ar
      ######################################################
      EOF
    ]

    connection {
      type        = "ssh"
      host        = self.public_ip
      user        = "ubuntu"
      private_key = var.private_key
    }
  }
}

resource "aws_instance" "worker" {
  count         = var.instance_count - 1
  ami           = var.ami
  instance_type = var.instance_type
  key_name      = aws_key_pair.k8s_key.key_name
  subnet_id     = aws_subnet.k8s_subnet.id

  root_block_device {
    volume_size = var.volume_workers_size
  }

  vpc_security_group_ids = [aws_security_group.this[count.index + 1].id]

  tags = {
    Name = "PICK-K8S-Worker-${count.index + 1}"
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOF
      cat <<EOF2 | sudo tee /etc/modules-load.d/k8s.conf
      overlay
      br_netfilter
      EOF2
      sudo modprobe overlay
      sudo modprobe br_netfilter
      cat <<EOF2 | sudo tee /etc/sysctl.d/k8s.conf
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      EOF2
      sudo sysctl --system
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
      sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg unzip nfs-kernel-server nfs-common bash-completion
      unzip awscliv2.zip
      sudo ./aws/install
      mkdir -p ~/.aws
      echo "[default]" | tee ~/.aws/config
      echo "aws_access_key_id=${var.AWS_ACCESS_KEY_ID}" | tee -a ~/.aws/config
      echo "aws_secret_access_key=${var.AWS_SECRET_ACCESS_KEY}" | tee -a ~/.aws/config
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
      sudo apt-get update
      sudo apt-get install -y kubelet kubeadm kubectl
      sudo apt-mark hold kubelet kubeadm kubectl
      sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update && sudo apt-get install -y containerd.io
      sudo containerd config default | sudo tee /etc/containerd/config.toml
      sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
      sudo systemctl restart containerd
      sudo systemctl enable --now kubelet
      ################ INSTALAR AUTOCOMPLETE E ALIAS ######################
      kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
      echo 'alias k=kubectl' >>~/.bashrc
      echo 'complete -F __start_kubectl k' >>~/.bashrc
      #####################################################################
      JOIN_COMMAND=$(aws ssm get-parameter --name "k8s_join_command" --query "Parameter.Value" --output text)
      sudo $JOIN_COMMAND
      ################ MONTANDO O NFS ######################
      sudo mkdir /mnt/nfs
      sudo chown $(id -u):$(id -g) /mnt/nfs
      sudo mount ${aws_instance.control_plane.private_ip}:/mnt/nfs /mnt/nfs
      ######################################################
      EOF
    ]

    connection {
      type        = "ssh"
      host        = self.public_ip
      user        = "ubuntu"
      private_key = var.private_key
    }
  }

  depends_on = [aws_instance.control_plane]
}
