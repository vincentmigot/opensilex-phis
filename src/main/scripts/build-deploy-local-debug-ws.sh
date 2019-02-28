#!/bin/bash
###############################################################################
##                        build-deploy-local-debug-ws.sh
## SILEX-PHIS
## Copyright © INRA 2018
## Creation date: 17 oct, 2018
## Contact: vincent.migot@inra.fr, anne.tireau@inra.fr, pascal.neveu@inra.fr
###############################################################################
#
# This script allow to build and deploy the local dev installation in debug mode.
# Configuration is loaded from /src/main/config/dev/localhost.properties
#
###############################################################################

###############################################################################
# Function to init main path
function initPath() {
    # Check if the script is directly launch from it's folder, typically via Netbeans
    if [[ "$PWD" == *src/main/scripts ]]
    then
        # In this case move to project root
        PROJECT_PATH=$PWD/../../..
    else
        # Otherwise assume that this script is launched from project root
        PROJECT_PATH=$PWD
    fi
    cd $PROJECT_PATH
    PROJECT_PATH=$PWD
    echo $PROJECT_PATH
}

###############################################################################
# Function to load configuration
function loadConfig() {
    # Read config file
    CONFIG_FILE="$PROJECT_PATH/src/main/config/dev/localhost.properties"
    echo "Load config file: $CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]
    then
        echo "$CONFIG_FILE found."

        # Read all variables in properties file, replace '.' by '_' in keys names
        while IFS='=' read -r key value
        do
            key=$(echo $key | tr '.' '_')
            if [[ ! -z "$key" && ! "$key" == \#* ]]
            then
                eval ${key}=\${value}
            fi
        done < "$CONFIG_FILE"

        # Check required variables existence
        function requireVariable() {
            eval "VAR=\$$1"
            if [[ -z $VAR ]]
            then
                echo "$1 property not defined in config file !"
                exit 2
            fi
        }

        requireVariable "INSTANCE_NAME"
        requireVariable "INSTANCE_VERSION"
        requireVariable "MAVEN_BIN"
        requireVariable "JDK"
        requireVariable "TOMCAT_PATH"

        # Display loaded variables
        echo "Instance name             = " ${INSTANCE_NAME}
        echo "Instance version          = " ${INSTANCE_VERSION}
        echo "Maven bin path            = " ${MAVEN_BIN}
        echo "JDK path                  = " ${JDK}
        echo "Tomcat base path          = " ${TOMCAT_PATH}
        echo "Tomcat hard reboot flag   = " ${TOMCAT_HARD_REBOOT}
        echo "Tomcat manager server uri = " ${TOMCAT_MANAGER_SERVER_URI}
        echo "Tomcat manager base uri   = " ${TOMCAT_MANAGER_BASE_URI}
        echo "Tomcat manager account    = " ${TOMCAT_MANAGER_ACCOUNT}
        echo "Tomcat manager password   = " ${TOMCAT_MANAGER_PASS}

    else
      echo "$CONFIG_FILE not found."
      exit 1
    fi
}

###############################################################################
# Function to run maven build
function buildMaven() {
    # Run maven clean install
    JAVA_HOME=$JDK $MAVEN_BIN clean install -Dopensilex.instance=$INSTANCE_NAME -Drevision=$INSTANCE_VERSION
    # Exit if maven clean install failed
    if [[ "$?" -ne 0 ]] ; then
        echo 'Error while building project, exiting...'
        exit 10
    fi
}

###############################################################################
# Function to copy builded war to Tomcat directory
function copyWar() {
    echo "Copy war file from project target folder to tomcat webapps folder"
    cp $PROJECT_PATH/target/opensilex-ws-$INSTANCE_VERSION.war $TOMCAT_PATH/webapps/$INSTANCE_NAME.war
    if [ $? -ne 0 ]
    then
        echo "Error during war file copy, exiting..."
        exit 20
    else
        echo "Done !"
    fi
}

###############################################################################
# Function to start tomcat with debug options
function startTomcat() {
    JAVA_HOME=$JDK JPDA_OPTS=$JPDA_OPTS $TOMCAT_PATH/bin/catalina.sh jpda start
}

###############################################################################
# Function to stop tomcat, eventually by force after 30s or directly if forced by flag
function stopTomcat() {
    # Get tomcat PID
    
    TOMCAT_PID=$(ps -ef | grep tomcat | grep java | awk ' { print $2 } ')

    if [ $TOMCAT_HARD_REBOOT ]
    then
        echo "Kill Tomcat process"
        kill -9 $TOMCAT_PID
    else
        echo "Error while reloading dynamically app, restarting tomcat..."
        WAITING_TIME=30
        ELAPSED_TIME=0
        SLEEP_TIME=5

        # Shutdown tomcat
        JAVA_HOME=$JDK $TOMCAT_PATH/bin/shutdown.sh

        # While PID exist wait 5 more seconds until 30 seconds max
        until [ `ps -p $TOMCAT_PID | grep -c $TOMCAT_PID` = '0' ] || [ $ELAPSED_TIME -gt $WAITING_TIME ]
        do
            echo "Waiting for processes to exit. Timeout before we kill the pid ${TOMCAT_PID}: ${ELAPSED_TIME}/${WAITING_TIME}"
            sleep $SLEEP_TIME
            let ELAPSED_TIME=$ELAPSED_TIME+$SLEEP_TIME;
        done

        # If maximum time is reached kill tomcat process
        if [ $ELAPSED_TIME -gt $WAITING_TIME ]; then
            echo "Killing processes which didn't stop after $WAITING_TIME seconds"
            kill -9 $TOMCAT_PID
        fi
    fi
}

###############################################################################
# Check if tomcat is running (define TOMCAT_UP variable)
function checkTomcatUp() {
    # Check if tomcat is alive
    TOMCAT_UP=$(curl -Is $TOMCAT_MANAGER_SERVER_URI | head -n 1)
}

###############################################################################
# Reload tomcat with Manager  text API (define TOMCAT_RESPONSE variable)
function reloadAppWithManager() {
    echo "Tomcat Manager URI is defined, try to reload app via text API"
    CURL_CMD="curl -s -w %{http_code} -u $TOMCAT_MANAGER_ACCOUNT:$TOMCAT_MANAGER_PASS $TOMCAT_MANAGER_SERVER_URI/$TOMCAT_MANAGER_BASE_URI/text/reload?path=/$INSTANCE_NAME"
    echo $CURL_CMD
    TOMCAT_RESPONSE=$($CURL_CMD)
}

###############################################################################
# Main script
###############################################################################

initPath

loadConfig

buildMaven

copyWar

echo "Clear logs"
echo > $TOMCAT_PATH/logs/catalina.out

checkTomcatUp

if [ "$TOMCAT_UP" ]
then
    echo "Tomcat up - reloading app"

    # Check if Tomcat Manager URI is defined
    if [ "$TOMCAT_MANAGER_SERVER_URI" != "" ] && [ "$TOMCAT_HARD_REBOOT" != "true" ]
    then
        # Reload app with tomcat manager text API
        reloadAppWithManager
        RESULT=$TOMCAT_RESPONSE
    else
        RESULT="KO - Tomcat Manager not configured, restart Tomcat by killing process"
    fi

    echo $RESULT

    # If tomcat manager response doesn't start with OK
    if [[ ! "$RESULT" == OK* ]]
    then
        # Stop Tomcat
        stopTomcat
        # Start Tomcat again with remote debugger
        startTomcat
    fi
else
    echo "Tomcat down - starting it !"
    # Start Tomcat with remote debugger
    startTomcat
fi
###############################################################################
