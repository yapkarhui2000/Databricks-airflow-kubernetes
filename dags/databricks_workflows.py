from airflow import DAG
from airflow.providers.databricks.operators.databricks import DatabricksRunNowOperator
from product_data_assets import posts_asset, user_asset

with DAG(
    dag_id= "databricks_workflows",
    schedule= (posts_asset & user_asset),
):
    run_databricks_workflow = DatabricksRunNowOperator(
        task_id = "run_databricks_workflow",
        databricks_conn_id = "databricks_conn",
        job_id ="377301544809522",
    )