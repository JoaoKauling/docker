#!/bin/ksh
ver=1.0 #Version
# #####################################################################################################
# PROC: services.sh
# TITLE: services.sh
# AUTHOR: Joao Kauling Neto
#
# REV     | DATE     | NAME       | COMMENT
# --------+----------+------------+---------------------------------------------------------
#  1.0    | 11.05.23 |Joao        | Initial Version
#         |          |            |
#
#
# Verifica status do cluster etcd
# etcdctl endpoint status --write-out=table
#
# Verifica os menbros do cluster etcd
# etcdctl member list
#
# Adiciona novo node etcd
# etcdctl member add novo-no --peer-urls http://<IP-do-novo-no>:2380
#
# Remove um node etcd
# etcdctl member remove <ID-do-membro>
######################################################################################################
return_code=1

if [ $# = 1 ] || [ $# = 2 ]; then

func=$1
service=$2
services_list="containerd|kubelet|etcd|kube-apiserver|kube-controller-manager|kube-scheduler|kube-proxy"

    function color_respc {

        tst=$(echo $respc |egrep "Error|Failed|failed|inactive")
        if [ -n "$tst" ];then
            # red
            respc="\033[31mnot running\033[0m"
            return_code=1
        else
            # green
            respc="\033[32mrunning\033[0m"
            return_code=0
        fi

    }

    function check_out {
        respc=$(systemctl check $service)
        color_respc
        #echo -e "$service\t status=$respc"
        printf "%-33s %b\n" "$service" "status=$respc"
    }

    function exec_func {
        func=$1
        if [ "$service" = "all" ] || [ "$service" = "ALL" ]; then

            systemctl list-units --type=service --all --quiet --no-pager --plain | egrep --color=auto "$services_list" | grep --color=auto loaded | awk '{print $1,$2,$3,$4}' | while read unit load active sub
            do
                if [ "$sub" = "failed" ]; then
                    service=$load
                else
                    service=$unit
                fi

                if [ "$func" = "check" ]; then
                    check_out
                else
                    sudo systemctl $func $service
                    check_out
                fi

            done

        else
            if [ "$func" = "check" ]; then
                check_out
            else
                sudo systemctl $func $service
                check_out
            fi
        fi
        echo ""
    }

    case "$func" in

        stop | STOP)
            exec_func "stop"
        ;;

        check | CHECK)
            exec_func "check"
        ;;

        status | STATUS)
            if [ "$service" = "all" ] || [ "$service" = "ALL" ]; then
                systemctl list-units --type=service --all --quiet --no-pager --plain | egrep --color=auto "$services_list" | grep --color=auto loaded | awk '{print $1,$2,$3,$4}' | while read unit load active sub
                do
                    status_output=$(systemctl status $unit)
                    echo "$status_output"
                    echo ""                    
                done
            else
                status_output=$(systemctl status $service)
                echo "$status_output"                      
                echo ""
            fi
        ;;

        restart | RESTART)
            exec_func "restart"
        ;;

        reload | RELOAD)
            exec_func "reload"
        ;;

        start | START)
            exec_func "start"
        ;;

        list | LIST)
            systemctl list-units --type=service --all --quiet --no-pager --plain | egrep --color=auto "$services_list" | grep --color=auto loaded | awk 'BEGIN{print "Unit LOAD   ACTIVE SUB"}; {print $1,$2,$3,$4}' | column -t
            echo ""
        ;;

        *)
        echo "Usage  $0 [start|stop|restart|reload|status|check]"
        ;;

     esac
else
    echo "Usage  $0 [start|stop|restart|reload|status|check]"
fi

