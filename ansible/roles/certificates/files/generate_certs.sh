#!/bin/bash

# Função de ajuda
function usage() {
  echo "Uso: $0 <arquivo_de_configuração> [-n] [-c] [-m] "
  echo ""
  echo "Opções:"
  echo "  <arquivo_de_configuração>  O arquivo .ini com as configurações."
  echo "  -n                    Gera todos os certificados."
  echo "  -c                    Gera os arquivos config"
  echo "  -m                    Move os certificados gerados para diretórios padrão."
  exit 1
}

#awk '/certificate-authority-data:/ {print $2}' /etc/kubernetes/kubelet.kubeconfig | base64 -d | openssl x509 -text --noout

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Erro: arquivo de configuração '$CONFIG_FILE' não encontrado."
  exit 1
fi

for cmd in openssl kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Erro: $cmd não está instalado."; exit 1; }
done

# Lê configurações do arquivo .ini
eval $(awk -F '=' '
  /^[^#]/ { gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2); config[$1]="\"" $2 "\"" }
  END { for (key in config) print key "=" config[key] }
' "$CONFIG_FILE")

OUTPUT_DIR=${output_dir:-/tmp/k8s_config}
CA_CONF=${ca_conf:-/tmp/k8s_config/ca.conf}
CA_DAYS=${ca_days:-3653}
CERT_DAYS=${cert_days:-3653}
CLUSTER_NAME=${cluster_name:-k8s}
KUBE_SERVER=${kube_server:-https://127.0.0.1:6443}
CONTROL_PLANE_SERVER=${control_plane_server:-https://127.0.0.1:6443}
CONTROL_PLANE_ADM=${control_plane_adm:-admin}
CERT_DIR=${cert_dir:-/etc/kubernetes/pki}
HOME_DIR=${home_dir:-/etc/kubernetes}
WORKER_NODE_USER=${worker_node_user:-root}

# Converte listas em arrays
control_plane_certificates=(${control_plane_certificates})
worker_node_list=(${worker_node_list})

# Cria o diretório de saída, se necessário
mkdir -p "$OUTPUT_DIR" || { echo "Erro ao criar diretório de saída: $OUTPUT_DIR"; exit 1; }

# Função para gerar certificados
function generate_certificates() {

  echo "Gerando chave da CA: ca.key..."
  openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096 || { echo "Erro ao gerar ca.key"; exit 1; }

  echo "Criando certificado da CA: ca.crt..."
  openssl req -x509 -new -sha512 -noenc \
    -key "$OUTPUT_DIR/ca.key" -days "$CA_DAYS" \
    -config "$CA_CONF" -section "req" \
    -out "$OUTPUT_DIR/ca.crt" || { echo "Erro ao criar ca.crt"; exit 1; }

   echo ""
   echo "-------------------------------------------"

  # Gera certificados para o plano de controle  
  # echo "${control_plane_certificates[@]}"
  for CERT_NAME in "${control_plane_certificates[@]}"; do
    echo "Gerando chave para: $CERT_NAME.key..."
    openssl genrsa -out "$OUTPUT_DIR/$CERT_NAME.key" 4096 || { echo "Erro ao gerar $CERT_NAME.key"; exit 1; }

    echo "Criando CSR para: $CERT_NAME..."
    openssl req -new -key "$OUTPUT_DIR/$CERT_NAME.key" -sha256 \
      -config "$CA_CONF" -section "$CERT_NAME" \
      -out "$OUTPUT_DIR/$CERT_NAME.csr" || { echo "Erro ao criar CSR para $CERT_NAME"; exit 1; }

    echo "Criando certificado para: $CERT_NAME.crt..."
    openssl x509 -req -days "$CERT_DAYS" -in "$OUTPUT_DIR/$CERT_NAME.csr" \
      -copy_extensions copyall \
      -sha256 -CA "$OUTPUT_DIR/ca.crt" \
      -CAkey "$OUTPUT_DIR/ca.key" \
      -CAcreateserial \
      -out "$OUTPUT_DIR/$CERT_NAME.crt" || { echo "Erro ao criar $CERT_NAME.crt"; exit 1; }
    echo ""
    echo "-------------------------------------------"
  done

  # Gera certificados para os nós worker
  for HOST in "${worker_node_list[@]}"; do
    echo "Gerando chave para: $HOST.key..."
    openssl genrsa -out "$OUTPUT_DIR/$HOST.key" 4096 || { echo "Erro ao gerar $HOST.key"; exit 1; }

    echo "Criando CSR para: $HOST..."
    openssl req -new -key "$OUTPUT_DIR/$HOST.key" -sha256 \
      -config "$CA_CONF" -section "$HOST" \
      -out "$OUTPUT_DIR/$HOST.csr" || { echo "Erro ao criar CSR para $HOST"; exit 1; }

    echo "Criando certificado para: $HOST.crt..."
    openssl x509 -req -days "$CERT_DAYS" -in "$OUTPUT_DIR/$HOST.csr" \
      -copy_extensions copyall \
      -sha256 -CA "$OUTPUT_DIR/ca.crt" \
      -CAkey "$OUTPUT_DIR/ca.key" \
      -CAcreateserial \
      -out "$OUTPUT_DIR/$HOST.crt" || { echo "Erro ao criar $HOST.crt"; exit 1; }

    rm "$OUTPUT_DIR/$HOST.csr"  

    echo ""
    echo "-------------------------------------------"
  done

  echo "Geração de certificados concluída!"
}

# Função para configurar kubeconfig
function configure_kubeconfig() {
  # Função auxiliar para configurar kubeconfig
  function setup_kubeconfig() {
    local kubeconfig_file=$1
    local kube_https=$2
    local cert_name=$3
    local user_name=$4

    kubectl config set-cluster "$CLUSTER_NAME" \
      --certificate-authority="$OUTPUT_DIR/ca.crt" \
      --embed-certs=true \
      --server="$kube_https" \
      --kubeconfig="$kubeconfig_file"

    kubectl config set-credentials "$user_name" \
      --client-certificate="$OUTPUT_DIR/$cert_name.crt" \
      --client-key="$OUTPUT_DIR/$cert_name.key" \
      --embed-certs=true \
      --kubeconfig="$kubeconfig_file"

    kubectl config set-context default \
      --cluster="$CLUSTER_NAME" \
      --user="$user_name" \
      --kubeconfig="$kubeconfig_file"

    kubectl config use-context default \
      --kubeconfig="$kubeconfig_file"
  }

  # Configura kubeconfig para os nós worker
  for HOST in "${worker_node_list[@]}"; do
    echo "Configurando kubeconfig para: $HOST..."
    setup_kubeconfig "$OUTPUT_DIR/$HOST.config" "$KUBE_SERVER" "$HOST" "system:node:$HOST"
    echo ""
    echo "-------------------------------------------"
  done

  # Configura kubeconfig para os binários
  for BINARY in "${control_plane_certificates[@]}"; do
    echo "Configurando kubeconfig para: $BINARY..."
    if [ "$BINARY" == "$CONTROL_PLANE_ADM" ]; then
      setup_kubeconfig "$OUTPUT_DIR/kubelet.config" "$CONTROL_PLANE_SERVER" "admin" "$CONTROL_PLANE_ADM"
    else
      setup_kubeconfig "$OUTPUT_DIR/${BINARY}.config" "$KUBE_SERVER" "$BINARY" "system:${BINARY}"
    fi
    echo ""
    echo "-------------------------------------------"
  done

}

# Função para mover os arquivos para os diretórios Kubernetes
function move_files() {
  echo "Movendo certificados e arquivos para diretórios padrão..."

  mkdir -p "$CERT_DIR" "$HOME_DIR" || { echo "Erro ao criar diretórios"; exit 1; }
  chmod 755 "$CERT_DIR" "$HOME_DIR"

  find "$OUTPUT_DIR" -name '*.key' -exec cp {} "$CERT_DIR/" \;
  find "$OUTPUT_DIR" -name '*.crt' -exec cp {} "$CERT_DIR/" \;
  find "$OUTPUT_DIR" -name '*.config' -exec cp {} "$HOME_DIR/" \;

  find "$OUTPUT_DIR" -name 'admin.key' -exec cp {} "$CERT_DIR/kubelet.key" \;
  find "$OUTPUT_DIR" -name 'admin.crt' -exec cp {} "$CERT_DIR/kubelet.crt" \;

  for HOST in "${worker_node_list[@]}"; do
    echo "Configurando $HOST..."

    # Cria o diretório no destino com sudo
    ssh $WORKER_NODE_USER@$HOST "mkdir -p /tmp/k8s_config" || {
      echo "Erro ao criar diretório em $HOST"
      continue
    }

    # Copia o certificado da CA para um diretório temporário e move para o destino
    scp ca.crt $WORKER_NODE_USER@$HOST:/tmp/k8s_config/ || {
      echo "Erro ao copiar ca.crt para $HOST"
      continue
    }
    # Copia o certificado do kubelet para um diretório temporário e move para o destino
    scp "$HOST.crt" $WORKER_NODE_USER@$HOST:/tmp/k8s_config/kubelet.crt || {
      echo "Erro ao copiar kubelet.crt para $HOST"
      continue
    }
    # Copia a chave do kubelet para um diretório temporário e move para o destino
    scp  "$HOST.key" $WORKER_NODE_USER@$HOST:/tmp/k8s_config/kubelet.key || {
      echo "Erro ao copiar kubelet.key para $HOST"
      continue
    }

    scp kube-proxy.config $WORKER_NODE_USER@$HOST:/tmp/k8s_config/kube-proxy.config || {
      echo "Erro ao copiar kube-proxy.config para $HOST"
      continue
    }

    scp ${HOST}.config $WORKER_NODE_USER@$HOST:/tmp/k8s_config/kubelet.config || {
      echo "Erro ao copiar kubelet.config para $HOST"
      continue
    }

    echo "Configuração concluída para $HOST."

  done


}

case $2 in
  -n ) generate_certificates ;;
  -c ) configure_kubeconfig ;;
  -m ) move_files ;;
  * ) usage ;;
esac

# Executa as funções
#generate_certificates
#configure_kubeconfig
#move_files

echo "Configuração e geração de certificados concluídas com sucesso!"
