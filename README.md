## Inspiration
The main inspiration for this project came from a previous project in Shellhacks 2024 called Hurrycane. The project consisted of a messaging system that allowed car drivers to communicate and pick up anyone who was about to be hit by a hurricane and had no mode of transportation. This idea of how vehicles can impact a community during a crisis was a major inspiration for our project. Another major motivation for our project was the higher amount of carbon emissions being reported on during our day to day lives. Having a way for regular people to track their carbon footprint and be able to do something about it encouraged us to make this.
## What it does
The iOS app connects to an OBD II sensor via bluetooth. This sensor is able to track a car's RPM, engine load, intake manifold, and current speed by connecting to a port underneath the steering wheel. With all of these statistics in mind, we are able to create a formula that calculates the car's average carbon footprint and display it on the iOS app.
## How we built it
We used Xcode in order to build the application as a whole, with the frontend being created from a swift framework, and the backend consisting of python files. The sensor itself uses Bluetooth Low Energy (BLE) connection in order to connect to a mobile device.
## Challenges we ran into
We ran into a few challenges during the making of this mobile application, most of these issues revolved around our novice understanding of mobile application development on iOS and the unusual way we had to connect to the OBD II sensor itself as well as retrieve its information. 
- For mobile application development, none of our team had much experience in developing mobile applications, especially on iOS with the restrictions it pushed on us. One of the biggest restrictions was the mandatory usage of xCode in order to build and run our mobile application. Our team only consisted of two members, and only one of them had a macbook and thus access to xCode, which required the team member with the macbook to stop all development whenever the mobile application needed to be  ran for testing purposes.
- As for the sensor itself, the first challenge we ran into was the way we had to connect to it. Due to the fact that the sensor used BLE, and not regular bluetooth connections like most other devices, we could not connect to the sensor through regular means in the iOS settings, but instead, had to write specific code that handles BLE connections in order to connect to the device within the app. 
- The sensor also handles its data in a unique hexadecimal format which is split into three major parts, the mode, the instruction, and the data itself.  It required us to decode each piece of data we are given before being able to display it or use it in calculations
# Accomplishments that we're proud of
We have been able to build a fully functioning iOS application which takes in all the data from the OBD II sensor, sends it to the backend for calculations, and then displays an accurate summation of a car's carbon footprint
## What we learned
We learned that we should be as familiar as we can be with any coding architecture or language that we decide to use for a project before we actually work on it. Especially for a very time sensitive project such as this.
## What's next for Car-Bon
As technology progresses, especially with smart displays in cars displaying more information for the driver, we would like to have this app be directly integrated into vehicles, instead of having to use third party tools to scan the data for us. We would also like a global database that is able to collect data from multiple regions. This data would then be used for comparing carbon footprints between regions, cities, or even countries in order to gather data not just on how much is being emitted per region, but also to figure out the underlying root of how and why these emissions are so high or so low in certain areas. Our longterm goal is to be able to gather as much data about emissions as we can, so we are able to efficiently and correctly prevent more emissions in a mission to become fully carbon neutral. 



Dependancies required to install:

    Frontend:
        Command Line tools for XCode
    Backend (pip install):
        uvicorn
        bleak

        pydantic
